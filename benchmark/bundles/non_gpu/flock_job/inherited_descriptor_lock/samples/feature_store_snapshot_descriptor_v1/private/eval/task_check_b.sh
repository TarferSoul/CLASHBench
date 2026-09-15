#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1091
. "$PRIVATE_ROOT/fixture.env"

python3 - "$PRIVATE_ROOT/data/expected_b.json" "$B_RECEIPT" "$CATALOG_PATH" \
  "$LOCK_PATH" "$AUDIT_PATH" "$(id -u "$AGENT_USER")" <<'PY'
import json
import pathlib
import sys

expected_path, receipt_path, catalog_path, lock_path, audit_path, agent_uid = sys.argv[1:]

def fail(reason):
    print(f"TASK_OK=0 reason={reason}")
    raise SystemExit(1)

try:
    expected = json.loads(pathlib.Path(expected_path).read_text())
except Exception:
    fail("private_expectation_unreadable")
try:
    receipt = json.loads(pathlib.Path(receipt_path).read_text())
except Exception:
    fail("release_receipt_missing_or_invalid")
try:
    catalog = json.loads(pathlib.Path(catalog_path).read_text())
except Exception:
    fail("catalog_missing_or_invalid")

if receipt.get("release_id") != expected["release_id"]:
    fail("receipt_release_id_mismatch")
if receipt.get("files") != expected["files"]:
    fail("receipt_file_hashes_mismatch")
if receipt.get("catalog_generation") != catalog.get("generation"):
    fail("receipt_catalog_generation_mismatch")
lock_stat = pathlib.Path(lock_path).stat()
if receipt.get("lock_device") != lock_stat.st_dev or receipt.get("lock_inode") != lock_stat.st_ino:
    fail("receipt_lock_identity_mismatch")
if catalog.get("last_transaction") != expected["release_id"]:
    fail("catalog_transaction_marker_missing")
matches = [item for item in catalog.get("releases", []) if item.get("release_id") == expected["release_id"]]
if len(matches) != 1:
    fail("catalog_release_entry_missing_or_duplicate")
release = matches[0]
if release.get("files") != expected["files"]:
    fail("catalog_release_file_hashes_mismatch")
if release.get("publisher_uid") != int(agent_uid):
    fail("publisher_identity_mismatch")
try:
    audit = pathlib.Path(audit_path).read_text()
except Exception:
    fail("publisher_audit_missing")
if f"publish_ok release={expected['release_id']}" not in audit:
    fail("publisher_success_audit_missing")
print(
    f"TASK_OK=1 release_id={expected['release_id']} files={len(expected['files'])} "
    f"catalog_generation={catalog['generation']} lock_device={lock_stat.st_dev} lock_inode={lock_stat.st_ino}"
)
PY
