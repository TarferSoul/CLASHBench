#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import signal
import sqlite3
import subprocess
import time
import uuid


def atomic_json(path, value):
    target = pathlib.Path(path)
    temporary = target.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, target)


def verify_manifest(root):
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
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if verified.returncode != 0:
        raise RuntimeError("mainline signature invalid")
    for migration in manifest["migrations"]:
        path = root / "migrations" / migration["file"]
        if hashlib.sha256(path.read_bytes()).hexdigest() != migration["sha256"]:
            raise RuntimeError("mainline migration checksum invalid")
    return manifest, hashlib.sha256(manifest_path.read_bytes()).hexdigest()


def project(database, manifest, manifest_sha, worker_id, sequence):
    connection = sqlite3.connect(database, timeout=3.0)
    current = connection.execute(
        """SELECT namespace, version, parent_version, migration_id, migration_checksum,
                  manifest_sha256, signer_key_id, release_id
           FROM release_lineage ORDER BY sequence DESC LIMIT 1"""
    ).fetchone()
    expected = (
        manifest["namespace"],
        manifest["version"],
        manifest["parent"],
        manifest["migration_id"],
        manifest["target_checksum"],
        manifest_sha,
        manifest["signer_key_id"],
        manifest["release_id"],
    )
    if current != expected:
        connection.close()
        raise RuntimeError("signed lineage mismatch")
    columns = {row[1] for row in connection.execute("PRAGMA table_info(feature_artifacts)")}
    if "validation_state" not in columns or "provenance_digest" in columns:
        connection.close()
        raise RuntimeError("mainline schema mismatch")
    policy_count = connection.execute("SELECT COUNT(*) FROM registry_validation_policy").fetchone()[0]
    if policy_count != 3:
        connection.close()
        raise RuntimeError("validation policy mismatch")
    artifacts = connection.execute(
        """SELECT artifact_id, model_family, object_sha256, lifecycle, validation_state
           FROM feature_artifacts ORDER BY artifact_id"""
    ).fetchall()
    digest = hashlib.sha256()
    for row in artifacts:
        digest.update(("|".join(str(value) for value in row) + "\n").encode())
    released_count = sum(row[3] == "released" for row in artifacts)
    catalog_digest = digest.hexdigest()
    connection.execute(
        """INSERT INTO registry_projection_audit(
               sequence, worker_id, release_id, artifact_count,
               released_count, catalog_digest, projected_at
           ) VALUES (?, ?, ?, ?, ?, ?, ?)""",
        (
            sequence,
            worker_id,
            manifest["release_id"],
            len(artifacts),
            released_count,
            catalog_digest,
            time.time(),
        ),
    )
    connection.commit()
    connection.close()
    return {
        "healthy": True,
        "worker_id": worker_id,
        "sequence": sequence,
        "namespace": manifest["namespace"],
        "release_id": manifest["release_id"],
        "version": manifest["version"],
        "checksum": manifest["target_checksum"],
        "artifact_count": len(artifacts),
        "released_count": released_count,
        "catalog_digest": catalog_digest,
        "heartbeat_at": time.time(),
        "pid": os.getpid(),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", required=True)
    parser.add_argument("--release-root", required=True)
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("--state-file", required=True)
    args = parser.parse_args()
    manifest, manifest_sha = verify_manifest(pathlib.Path(args.release_root).resolve())
    worker_id = str(uuid.uuid4())
    stop = False

    def request_stop(_signum, _frame):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    atomic_json(args.pid_file, {"pid": os.getpid(), "worker_id": worker_id})
    sequence = 0
    while not stop:
        sequence += 1
        atomic_json(args.state_file, project(args.database, manifest, manifest_sha, worker_id, sequence))
        time.sleep(0.16)


if __name__ == "__main__":
    main()
