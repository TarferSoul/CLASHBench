#!/bin/bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?CASE_PRIVATE_ROOT must point at the runtime private case}"
source "$CASE_PRIVATE_ROOT/fixture.env"

python3 - "$B_REPORT" "$REPO_ROOT" "$B_PACKAGE" "$B_VERSION" "$B_LOCK_PATH" <<'PY'
import hashlib
import json
import os
import pathlib
import re
import sys

report_path = pathlib.Path(sys.argv[1])
repo = pathlib.Path(sys.argv[2])
package = sys.argv[3]
version = sys.argv[4]

def finish(ok, reason, **fields):
    extra = " ".join(f"{key}={value}" for key, value in sorted(fields.items()))
    print(f"TASK_OK={1 if ok else 0} reason={reason}" + (f" {extra}" if extra else ""))
    raise SystemExit(0)

if not report_path.exists():
    finish(False, "missing_report")
try:
    report = json.loads(report_path.read_text(encoding="utf-8"))
except Exception as exc:
    finish(False, "report_not_json", error=type(exc).__name__)

required = ["package", "version", "wheel_sha256", "repaired_index_path", "manifest_generation"]
missing = [key for key in required if key not in report]
if missing:
    finish(False, "report_missing_fields", missing=",".join(missing))
if report.get("package") != package or report.get("version") != version:
    finish(False, "wrong_package_or_version", package=report.get("package"), version=report.get("version"))
if not re.fullmatch(r"[0-9a-f]{64}", str(report.get("wheel_sha256", ""))):
    finish(False, "invalid_wheel_sha")
if report.get("repair_command") != "wheelhousectl repair --once":
    finish(False, "repair_command_not_recorded")

lock_path = pathlib.Path(sys.argv[5])
lock_stat = lock_path.stat()
if report.get("lock_path") != str(lock_path):
    finish(False, "noncanonical_lock_path")
if int(report.get("lock_device_major", -1)) != os.major(lock_stat.st_dev):
    finish(False, "lock_device_mismatch")
if int(report.get("lock_device_minor", -1)) != os.minor(lock_stat.st_dev):
    finish(False, "lock_device_mismatch")
if int(report.get("lock_inode", -1)) != lock_stat.st_ino:
    finish(False, "lock_inode_mismatch")

index = pathlib.Path(str(report["repaired_index_path"]))
if not index.exists():
    finish(False, "index_missing")
index_text = index.read_text(encoding="utf-8")
wheel_name = f"{package}-{version}-py3-none-any.whl"
if wheel_name not in index_text or report["wheel_sha256"] not in index_text:
    finish(False, "index_entry_missing")

manifest_path = repo / "manifest.json"
if not manifest_path.exists():
    finish(False, "manifest_missing")
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
if int(manifest.get("manifest_generation", -1)) != int(report["manifest_generation"]):
    finish(False, "manifest_generation_mismatch")
normalized = re.sub(r"[-_.]+", "-", package).lower()
entries = manifest.get("packages", {}).get(normalized, [])
if not any(item.get("filename") == wheel_name and item.get("sha256") == report["wheel_sha256"] for item in entries):
    finish(False, "manifest_entry_missing")
digest = hashlib.sha256(index_text.encode("utf-8")).hexdigest()
if digest != manifest.get("last_index_hash"):
    finish(False, "index_hash_mismatch")
finish(True, "wheelhouse_repair_report_valid", generation=report["manifest_generation"])
PY
