#!/usr/bin/env python3
import argparse
import hashlib
import importlib.metadata
import json
import pathlib
import sqlite3
import subprocess
import sys
import time


NAMESPACE = "ml-feature-registry/catalog-schema"
ENGINE_VERSION = "9.0.0"


def sha256_file(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_release(root):
    manifest_path = root / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    verified = subprocess.run(
        [
            "openssl",
            "dgst",
            "-sha256",
            "-verify",
            str(root / "public_key.pem"),
            "-signature",
            str(root / "manifest.sig"),
            str(manifest_path),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if verified.returncode != 0:
        raise RuntimeError(f"signature verification failed for {root}")
    for migration in manifest["migrations"]:
        path = root / "migrations" / migration["file"]
        if sha256_file(path) != migration["sha256"]:
            raise RuntimeError(f"migration checksum failed for {path}")
    if manifest["target_checksum"] != next(
        item["sha256"] for item in manifest["migrations"] if item["id"] == manifest["migration_id"]
    ):
        raise RuntimeError("target checksum is inconsistent")
    if manifest["engine"] != {"name": "yoyo-migrations", "version": ENGINE_VERSION}:
        raise RuntimeError("engine pin mismatch")
    if importlib.metadata.version("yoyo-migrations") != ENGINE_VERSION:
        raise RuntimeError("installed yoyo version mismatch")
    return manifest, sha256_file(manifest_path)


def run_yoyo(database, migrations):
    completed = subprocess.run(
        [
            sys.executable,
            "-m",
            "yoyo",
            "--no-config-file",
            "--batch",
            "apply",
            "--database",
            f"sqlite:///{database.resolve()}",
            str(migrations),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if completed.returncode != 0:
        raise RuntimeError(f"yoyo apply failed rc={completed.returncode}: {completed.stdout[-2000:]}")
    return completed.stdout


def create_base(database, rows):
    for suffix in ("", "-wal", "-shm"):
        try:
            pathlib.Path(str(database) + suffix).unlink()
        except FileNotFoundError:
            pass
    database.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(database)
    connection.executescript(
        """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=FULL;
        CREATE TABLE feature_artifacts (
            artifact_id TEXT PRIMARY KEY,
            model_family TEXT NOT NULL,
            object_sha256 TEXT NOT NULL,
            lifecycle TEXT NOT NULL,
            created_at TEXT NOT NULL
        );
        CREATE TABLE release_lineage (
            sequence INTEGER PRIMARY KEY,
            namespace TEXT NOT NULL,
            version TEXT NOT NULL,
            parent_version TEXT NOT NULL,
            migration_id TEXT NOT NULL,
            migration_checksum TEXT NOT NULL,
            manifest_sha256 TEXT NOT NULL,
            signer_key_id TEXT NOT NULL,
            release_id TEXT NOT NULL,
            applied_at REAL NOT NULL,
            UNIQUE(namespace, version)
        );
        CREATE TRIGGER release_lineage_no_update
        BEFORE UPDATE ON release_lineage
        BEGIN
            SELECT RAISE(ABORT, 'release_lineage is append-only');
        END;
        CREATE TRIGGER release_lineage_no_delete
        BEFORE DELETE ON release_lineage
        BEGIN
            SELECT RAISE(ABORT, 'release_lineage is append-only');
        END;
        CREATE TABLE registry_projection_audit (
            sequence INTEGER PRIMARY KEY,
            worker_id TEXT NOT NULL,
            release_id TEXT NOT NULL,
            artifact_count INTEGER NOT NULL,
            released_count INTEGER NOT NULL,
            catalog_digest TEXT NOT NULL,
            projected_at REAL NOT NULL
        );
        """
    )
    families = ("vision-encoder", "text-reranker", "speech-decoder", "tabular-forecast")
    lifecycles = ("released", "candidate", "released", "quarantined")
    values = []
    for index in range(1, rows + 1):
        artifact_id = f"artifact-{index:04d}"
        family = families[index % len(families)]
        object_sha = hashlib.sha256(f"{artifact_id}:{family}:object".encode()).hexdigest()
        values.append(
            (
                artifact_id,
                family,
                object_sha,
                lifecycles[index % len(lifecycles)],
                f"2026-08-{(index % 20) + 1:02d}T{index % 24:02d}:00:00Z",
            )
        )
    connection.executemany(
        """INSERT INTO feature_artifacts(
               artifact_id, model_family, object_sha256, lifecycle, created_at
           ) VALUES (?, ?, ?, ?, ?)""",
        values,
    )
    connection.commit()
    connection.close()


def insert_lineage(database, manifest, manifest_sha, include_target):
    predecessor = manifest["predecessor"]
    connection = sqlite3.connect(database)
    connection.execute(
        """INSERT INTO release_lineage(
               sequence, namespace, version, parent_version, migration_id,
               migration_checksum, manifest_sha256, signer_key_id, release_id, applied_at
           ) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (
            NAMESPACE,
            predecessor["version"],
            predecessor["parent"],
            predecessor["migration_id"],
            predecessor["checksum"],
            predecessor["attestation_sha256"],
            manifest["signer_key_id"],
            "FR-BASE-2026.08.1",
            time.time(),
        ),
    )
    if include_target:
        connection.execute(
            """INSERT INTO release_lineage(
                   sequence, namespace, version, parent_version, migration_id,
                   migration_checksum, manifest_sha256, signer_key_id, release_id, applied_at
               ) VALUES (2, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                NAMESPACE,
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
    connection.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", required=True)
    parser.add_argument("--lineage", choices=("a", "b-predecessor"), required=True)
    parser.add_argument("--data-root", required=True)
    parser.add_argument("--rows", type=int, default=180)
    args = parser.parse_args()
    database = pathlib.Path(args.database).resolve()
    data_root = pathlib.Path(args.data_root).resolve()
    release_root = data_root / ("a_release" if args.lineage == "a" else "b_release")
    manifest, manifest_sha = verify_release(release_root)
    create_base(database, args.rows)
    if args.lineage == "a":
        migrations = release_root / "migrations"
        include_target = True
    else:
        migrations = data_root / "b_predecessor" / "migrations"
        predecessor_file = next(migrations.glob("*.sql"))
        if sha256_file(predecessor_file) != manifest["predecessor"]["checksum"]:
            raise RuntimeError("predecessor fixture does not match signed predecessor")
        include_target = False
    engine_output = run_yoyo(database, migrations)
    insert_lineage(database, manifest, manifest_sha, include_target)
    connection = sqlite3.connect(database)
    history = [row[0] for row in connection.execute("SELECT migration_id FROM _yoyo_migration ORDER BY applied_at_utc")]
    current = connection.execute(
        "SELECT version, migration_checksum, release_id FROM release_lineage ORDER BY sequence DESC LIMIT 1"
    ).fetchone()
    count = connection.execute("SELECT COUNT(*) FROM feature_artifacts").fetchone()[0]
    connection.close()
    print(
        f"FIXTURE_READY=1 lineage={args.lineage} rows={count} current={current[0]} "
        f"checksum={current[1]} release={current[2]} "
        f"engine_output_sha256={hashlib.sha256(engine_output.encode()).hexdigest()} history={','.join(history)}"
    )


if __name__ == "__main__":
    main()
