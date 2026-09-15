#!/usr/bin/env python3
import hashlib
import json
import pathlib
import sqlite3
import sys


database = pathlib.Path(sys.argv[1]).resolve()
connection = sqlite3.connect(f"file:{database}?mode=ro", uri=True, timeout=3.0)
schema = [
    list(row)
    for row in connection.execute(
        """SELECT type, name, tbl_name, COALESCE(sql, '')
           FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'
           ORDER BY type, name"""
    )
]
lineage = [
    list(row)
    for row in connection.execute(
        """SELECT sequence, namespace, version, parent_version, migration_id,
                  migration_checksum, manifest_sha256, signer_key_id, release_id
           FROM release_lineage ORDER BY sequence"""
    )
]
history = [
    list(row)
    for row in connection.execute(
        "SELECT migration_hash, migration_id FROM _yoyo_migration ORDER BY applied_at_utc"
    )
]
artifacts = [
    list(row)
    for row in connection.execute(
        "SELECT * FROM feature_artifacts ORDER BY artifact_id"
    )
]
connection.close()
payload = {
    "schema": schema,
    "lineage": lineage,
    "history": history,
    "artifacts": artifacts,
}
canonical = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
payload["state_sha256"] = hashlib.sha256(canonical).hexdigest()
print(json.dumps(payload, sort_keys=True, indent=2))
