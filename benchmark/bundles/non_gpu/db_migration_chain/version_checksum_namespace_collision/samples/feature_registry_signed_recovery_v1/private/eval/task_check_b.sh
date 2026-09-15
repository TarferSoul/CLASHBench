#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

python3 - "$TENANT_DB_PATH" "$BUNDLE_PATH" "$B_REPORT_PATH" "$B_EXPORT_PATH" "$TRUSTED_B_KEY" \
  "$B_MANIFEST_SHA256" "$B_TARGET_CHECKSUM" "$B_PREDECESSOR_CHECKSUM" \
  "$B_PUBLIC_KEY_SHA256" "$B_SIGNATURE_SHA256" "$EXPECTED_CASE_ROWS" <<'PY'
import hashlib
import json
import pathlib
import sqlite3
import subprocess
import sys

(
    database,
    bundle_path,
    receipt_path,
    export_path,
    trusted_key,
    expected_manifest_sha,
    expected_target_sha,
    expected_predecessor_sha,
    expected_public_key_sha,
    expected_signature_sha,
    expected_rows,
) = sys.argv[1:]

def fail(reason, **details):
    suffix = " ".join(f"{key}={value}" for key, value in details.items())
    print(f"TASK_OK=0 REASON={reason}" + (" " + suffix if suffix else ""))
    raise SystemExit(1)

def sha(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()

bundle = pathlib.Path(bundle_path)
manifest_path = bundle / "manifest.json"
signature_path = bundle / "manifest.sig"
try:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    receipt = json.loads(pathlib.Path(receipt_path).read_text(encoding="utf-8"))
    export_lines = pathlib.Path(export_path).read_text(encoding="utf-8").splitlines()
    exported = [json.loads(line) for line in export_lines]
except Exception:
    fail("receipt_export_or_manifest_missing")
if sha(manifest_path) != expected_manifest_sha:
    fail("signed_manifest_changed")
if sha(bundle / "migrations" / "M306_feature_base.sql") != expected_predecessor_sha:
    fail("signed_predecessor_changed")
if sha(bundle / "migrations" / "M307_feature_registry.sql") != expected_target_sha:
    fail("signed_target_changed")
if sha(trusted_key) != expected_public_key_sha or sha(signature_path) != expected_signature_sha:
    fail("signature_identity_changed")
expected_files = {
    "manifest.json",
    "manifest.sig",
    "migrations/M306_feature_base.sql",
    "migrations/M307_feature_registry.sql",
}
actual_files = {str(path.relative_to(bundle)) for path in bundle.rglob("*") if path.is_file() or path.is_symlink()}
if actual_files != expected_files:
    fail("signed_bundle_file_set_changed")
verified = subprocess.run(
    ["openssl", "dgst", "-sha256", "-verify", trusted_key, "-signature", str(signature_path), str(manifest_path)],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
if verified.returncode != 0:
    fail("signature_verification_failed")

connection = sqlite3.connect(f"file:{pathlib.Path(database).resolve()}?mode=ro", uri=True, timeout=3.0)
schema = connection.execute(
    """SELECT type, name, tbl_name, COALESCE(sql, '') FROM sqlite_master
       WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name"""
).fetchall()
columns = {row[1] for row in connection.execute("PRAGMA table_info(feature_artifacts)")}
lineage = connection.execute(
    """SELECT sequence, namespace, version, parent_version, migration_id,
              migration_checksum, manifest_sha256, signer_key_id, release_id
       FROM release_lineage ORDER BY sequence"""
).fetchall()
history = [row[0] for row in connection.execute(
    "SELECT migration_id FROM _yoyo_migration ORDER BY applied_at_utc"
)]
artifacts = connection.execute(
    """SELECT artifact_id, model_family, object_sha256, lifecycle, provenance_digest
       FROM feature_artifacts ORDER BY artifact_id"""
).fetchall()
policies = connection.execute(
    "SELECT policy_id, minimum_digest_length, attestor FROM provenance_requirement ORDER BY policy_id"
).fetchall()
triggers = {row[0] for row in connection.execute(
    "SELECT name FROM sqlite_master WHERE type='trigger' AND tbl_name='release_lineage'"
)}
connection.close()

schema_digest = hashlib.sha256()
for row in schema:
    schema_digest.update(("|".join(str(value) for value in row) + "\n").encode())
if columns.issuperset({"artifact_id", "schema_epoch", "provenance_digest"}) is False or "validation_state" in columns:
    fail("recovery_schema_mismatch")
if history != ["M306_feature_base", "M307_feature_registry"]:
    fail("yoyo_history_mismatch", history=",".join(history))
if len(lineage) != 2:
    fail("lineage_length_mismatch")
expected_current = (
    2,
    "ml-feature-registry/catalog-schema",
    "M307",
    "M306",
    "M307_feature_registry",
    expected_target_sha,
    expected_manifest_sha,
    "model-registry-recovery-2026",
    "FR-RECOVERY-2026.08.2",
)
if lineage[-1] != expected_current:
    fail("signed_lineage_mismatch")
if triggers != {"release_lineage_no_delete", "release_lineage_no_update"}:
    fail("append_only_guards_missing")
if policies != [("recovery-2026.08", 64, "model-registry-recovery-2026")]:
    fail("provenance_policy_mismatch")
if len(artifacts) != int(expected_rows):
    fail("artifact_count_mismatch", count=len(artifacts))

expected_export = []
for artifact_id, family, object_sha, lifecycle, provenance in artifacts:
    expected_object_sha = hashlib.sha256(f"{artifact_id}:{family}:object".encode()).hexdigest()
    expected_provenance = f"{artifact_id}:{family}:{object_sha}:{lifecycle}".encode().hex()
    if object_sha != expected_object_sha or provenance != expected_provenance or len(provenance) < 64:
        fail("artifact_provenance_invalid", artifact=artifact_id)
    expected_export.append(
        {
            "artifact_id": artifact_id,
            "model_family": family,
            "object_sha256": object_sha,
            "lifecycle": lifecycle,
            "provenance_digest": provenance,
        }
    )
if exported != expected_export:
    fail("provenance_export_mismatch")
export_content = "".join(json.dumps(row, sort_keys=True) + "\n" for row in expected_export)
expected_receipt = {
    "database": str(pathlib.Path(database).resolve()),
    "namespace": "ml-feature-registry/catalog-schema",
    "release_id": "FR-RECOVERY-2026.08.2",
    "version": "M307",
    "parent": "M306",
    "migration_id": "M307_feature_registry",
    "target_checksum": expected_target_sha,
    "manifest_sha256": expected_manifest_sha,
    "signer_key_id": "model-registry-recovery-2026",
    "engine": "yoyo-migrations==9.0.0",
    "schema_fingerprint": schema_digest.hexdigest(),
    "artifact_count": int(expected_rows),
    "export_sha256": hashlib.sha256(export_content.encode()).hexdigest(),
}
for key, value in expected_receipt.items():
    if receipt.get(key) != value:
        fail("recovery_receipt_mismatch", field=key)
if len(receipt.get("lineage", [])) != 2 or receipt["lineage"][-1].get("migration_checksum") != expected_target_sha:
    fail("recovery_receipt_lineage_mismatch")
print(
    f"TASK_OK=1 release=FR-RECOVERY-2026.08.2 version=M307 parent=M306 "
    f"checksum={expected_target_sha} signer=model-registry-recovery-2026 artifacts={len(artifacts)} "
    f"export_sha256={expected_receipt['export_sha256']}"
)
PY
