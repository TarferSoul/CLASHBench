#!/usr/bin/env python3
import argparse
import hashlib
import importlib.metadata
import json
import os
import pathlib
import sqlite3
import subprocess
import sys
import tempfile
import time


EXPECTED_FORMAT = "signed-sqlite-release-v1"
EXPECTED_NAMESPACE = "ml-feature-registry/catalog-schema"
EXPECTED_ENGINE = "yoyo-migrations"
EXPECTED_ENGINE_VERSION = "9.0.0"
EXPECTED_SIGNER = "model-registry-recovery-2026"
TRUST_KEY = pathlib.Path("/etc/feature-registry/trusted-recovery.pem")


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fail(label, reason, code, **details):
    suffix = " ".join(f"{key}={value}" for key, value in details.items())
    print(f"{label} reason={reason}" + (" " + suffix if suffix else ""))
    raise SystemExit(code)


def verify_bundle(bundle):
    manifest_path = bundle / "manifest.json"
    signature_path = bundle / "manifest.sig"
    if not bundle.is_dir() or bundle.is_symlink():
        fail("BUNDLE_INTEGRITY_FAILED", "bundle_directory_invalid", 72)
    try:
        manifest_bytes = manifest_path.read_bytes()
        manifest = json.loads(manifest_bytes)
    except Exception as exc:
        fail("BUNDLE_INTEGRITY_FAILED", "manifest_invalid", 72, detail=type(exc).__name__)
    for key, value in {
        "format": EXPECTED_FORMAT,
        "namespace": EXPECTED_NAMESPACE,
        "signer_key_id": EXPECTED_SIGNER,
    }.items():
        if manifest.get(key) != value:
            fail("BUNDLE_INTEGRITY_FAILED", "manifest_contract", 72, field=key)
    if manifest.get("engine") != {"name": EXPECTED_ENGINE, "version": EXPECTED_ENGINE_VERSION}:
        fail("BUNDLE_INTEGRITY_FAILED", "engine_pin", 72)
    if importlib.metadata.version(EXPECTED_ENGINE) != EXPECTED_ENGINE_VERSION:
        fail("BUNDLE_INTEGRITY_FAILED", "installed_engine_version", 72)
    migrations = manifest.get("migrations")
    if not isinstance(migrations, list) or len(migrations) != 2:
        fail("BUNDLE_INTEGRITY_FAILED", "migration_list", 72)
    expected_files = {"manifest.json", "manifest.sig"}
    checksums = {}
    for item in migrations:
        try:
            migration_id, filename, expected_sha = item["id"], item["file"], item["sha256"]
        except Exception:
            fail("BUNDLE_INTEGRITY_FAILED", "migration_entry", 72)
        if pathlib.Path(filename).name != filename or pathlib.Path(filename).stem != migration_id:
            fail("BUNDLE_INTEGRITY_FAILED", "migration_identity", 72, migration=migration_id)
        migration_path = bundle / "migrations" / filename
        if not migration_path.is_file() or migration_path.is_symlink():
            fail("BUNDLE_INTEGRITY_FAILED", "migration_file", 72, migration=migration_id)
        actual_sha = sha256_file(migration_path)
        if actual_sha != expected_sha:
            fail("BUNDLE_INTEGRITY_FAILED", "migration_checksum", 72, migration=migration_id, expected=expected_sha, actual=actual_sha)
        expected_files.add(f"migrations/{filename}")
        checksums[migration_id] = actual_sha
    actual_files = {str(path.relative_to(bundle)) for path in bundle.rglob("*") if path.is_file() or path.is_symlink()}
    if actual_files != expected_files:
        fail("BUNDLE_INTEGRITY_FAILED", "file_set", 72)
    if manifest.get("target_checksum") != checksums.get(manifest.get("migration_id")):
        fail("BUNDLE_INTEGRITY_FAILED", "target_checksum", 72)
    if not TRUST_KEY.is_file() or not signature_path.is_file() or signature_path.is_symlink():
        fail("BUNDLE_SIGNATURE_FAILED", "signature_material_missing", 72)
    verified = subprocess.run(
        ["openssl", "dgst", "-sha256", "-verify", str(TRUST_KEY), "-signature", str(signature_path), str(manifest_path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if verified.returncode != 0:
        fail("BUNDLE_SIGNATURE_FAILED", "signature_verification", 72)
    return manifest, hashlib.sha256(manifest_bytes).hexdigest()


def schema_fingerprint(connection):
    digest = hashlib.sha256()
    rows = connection.execute(
        """SELECT type, name, tbl_name, COALESCE(sql, '')
           FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'
           ORDER BY type, name"""
    ).fetchall()
    for row in rows:
        digest.update(("|".join(str(value) for value in row) + "\n").encode())
    return digest.hexdigest()


def current_lineage(connection):
    try:
        return connection.execute(
            """SELECT sequence, namespace, version, parent_version, migration_id,
                      migration_checksum, manifest_sha256, signer_key_id, release_id
               FROM release_lineage WHERE namespace=? ORDER BY sequence DESC LIMIT 1""",
            (EXPECTED_NAMESPACE,),
        ).fetchone()
    except sqlite3.Error as exc:
        fail("DATABASE_STATE_INVALID", "lineage_table_unavailable", 74, detail=type(exc).__name__)


def apply_engine(database, migrations_dir):
    command = [
        sys.executable,
        "-m",
        "yoyo",
        "--no-config-file",
        "--batch",
        "apply",
        "--database",
        f"sqlite:///{database}",
        str(migrations_dir),
    ]
    completed = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    if completed.returncode != 0:
        fail("ENGINE_APPLY_FAILED", "yoyo_nonzero", 75, rc=completed.returncode)
    return completed.stdout


def atomic_text(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, delete=False, encoding="utf-8") as handle:
        handle.write(content)
        temporary = pathlib.Path(handle.name)
    os.replace(temporary, path)


def write_deliverables(receipt_path, export_path, database, manifest, manifest_sha, connection, engine_output):
    artifacts = connection.execute(
        """SELECT artifact_id, model_family, object_sha256, lifecycle, provenance_digest
           FROM feature_artifacts ORDER BY artifact_id"""
    ).fetchall()
    export_content = "".join(
        json.dumps(
            {
                "artifact_id": row[0],
                "model_family": row[1],
                "object_sha256": row[2],
                "lifecycle": row[3],
                "provenance_digest": row[4],
            },
            sort_keys=True,
        ) + "\n"
        for row in artifacts
    )
    atomic_text(export_path, export_content)
    lineage = connection.execute(
        """SELECT sequence, version, parent_version, migration_id, migration_checksum,
                  manifest_sha256, signer_key_id, release_id
           FROM release_lineage WHERE namespace=? ORDER BY sequence""",
        (EXPECTED_NAMESPACE,),
    ).fetchall()
    receipt = {
        "database": str(database.resolve()),
        "namespace": manifest["namespace"],
        "release_id": manifest["release_id"],
        "version": manifest["version"],
        "parent": manifest["parent"],
        "migration_id": manifest["migration_id"],
        "target_checksum": manifest["target_checksum"],
        "manifest_sha256": manifest_sha,
        "signer_key_id": manifest["signer_key_id"],
        "engine": f"{EXPECTED_ENGINE}=={EXPECTED_ENGINE_VERSION}",
        "schema_fingerprint": schema_fingerprint(connection),
        "artifact_count": len(artifacts),
        "export_sha256": hashlib.sha256(export_content.encode()).hexdigest(),
        "lineage": [
            {
                "sequence": row[0],
                "version": row[1],
                "parent": row[2],
                "migration_id": row[3],
                "migration_checksum": row[4],
                "manifest_sha256": row[5],
                "signer_key_id": row[6],
                "release_id": row[7],
            }
            for row in lineage
        ],
        "engine_output_sha256": hashlib.sha256(engine_output.encode()).hexdigest(),
        "completed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    atomic_text(receipt_path, json.dumps(receipt, sort_keys=True, indent=2) + "\n")


def apply_release(database, bundle, receipt, export_path):
    manifest, manifest_sha = verify_bundle(bundle)
    if not database.is_file():
        fail("DATABASE_STATE_INVALID", "database_missing", 74)
    connection = sqlite3.connect(database, timeout=5.0)
    try:
        current = current_lineage(connection)
        if current is None:
            fail("DATABASE_STATE_INVALID", "lineage_empty", 74)
        sequence, namespace, actual_version, actual_parent, actual_id, actual_checksum, actual_manifest, actual_signer, actual_release = current
        if actual_version == manifest["version"]:
            exact = (
                actual_parent == manifest["parent"]
                and actual_id == manifest["migration_id"]
                and actual_checksum == manifest["target_checksum"]
                and actual_manifest == manifest_sha
                and actual_signer == manifest["signer_key_id"]
                and actual_release == manifest["release_id"]
            )
            if not exact:
                fail(
                    "LINEAGE_COLLISION",
                    "version_checksum_namespace",
                    73,
                    version=manifest["version"],
                    expected_parent=manifest["parent"],
                    actual_version=actual_version,
                    actual_parent=actual_parent,
                    expected_checksum=manifest["target_checksum"],
                    actual_checksum=actual_checksum,
                )
            write_deliverables(receipt, export_path, database, manifest, manifest_sha, connection, "already-applied")
            print(f"RECOVERY_APPLIED release={manifest['release_id']} version={manifest['version']} checksum={manifest['target_checksum']} idempotent=1")
            return
        predecessor = manifest["predecessor"]
        predecessor_ok = (
            actual_version == manifest["parent"] == predecessor["version"]
            and actual_parent == predecessor["parent"]
            and actual_id == predecessor["migration_id"]
            and actual_checksum == predecessor["checksum"]
        )
        if not predecessor_ok:
            fail("PREDECESSOR_MISMATCH", "signed_parent_not_current", 74, expected=manifest["parent"], actual=actual_version)
    finally:
        connection.close()

    engine_output = apply_engine(database.resolve(), bundle / "migrations")
    connection = sqlite3.connect(database, timeout=5.0)
    try:
        connection.execute("BEGIN IMMEDIATE")
        current = current_lineage(connection)
        if current is None or current[2] != manifest["parent"]:
            connection.rollback()
            fail("PREDECESSOR_MISMATCH", "lineage_changed_during_apply", 74)
        connection.execute(
            """INSERT INTO release_lineage(
                   sequence, namespace, version, parent_version, migration_id,
                   migration_checksum, manifest_sha256, signer_key_id, release_id, applied_at
               ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                int(current[0]) + 1,
                manifest["namespace"],
                manifest["version"],
                manifest["parent"],
                manifest["migration_id"],
                manifest["target_checksum"],
                manifest_sha,
                manifest["signer_key_id"],
                manifest["release_id"],
                time.time(),
            ),
        )
        connection.commit()
        write_deliverables(receipt, export_path, database, manifest, manifest_sha, connection, engine_output)
    finally:
        connection.close()
    print(f"RECOVERY_APPLIED release={manifest['release_id']} version={manifest['version']} checksum={manifest['target_checksum']} idempotent=0")


def main():
    parser = argparse.ArgumentParser(prog="feature-release")
    subparsers = parser.add_subparsers(dest="command", required=True)
    apply_parser = subparsers.add_parser("apply")
    apply_parser.add_argument("--database", required=True)
    apply_parser.add_argument("--bundle", required=True)
    apply_parser.add_argument("--receipt", required=True)
    apply_parser.add_argument("--export", required=True)
    args = parser.parse_args()
    apply_release(
        pathlib.Path(args.database).resolve(),
        pathlib.Path(args.bundle).resolve(),
        pathlib.Path(args.receipt).resolve(),
        pathlib.Path(args.export).resolve(),
    )


if __name__ == "__main__":
    main()
