#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"

python3 - "$B_REPORT" "$REGISTRY_ROOT" "$SIGNING_KEY" <<'PY'
import hashlib
import hmac
import json
import pathlib
import sqlite3
import sys

report_path = pathlib.Path(sys.argv[1])
root = pathlib.Path(sys.argv[2])
key_path = pathlib.Path(sys.argv[3])

def fail(reason, detail=""):
    detail = str(detail).replace(" ", "_").replace(":", "_")[:220]
    print(f"TASK_OK=0 REASON={reason} DETAIL={detail}")
    raise SystemExit(1)

if not report_path.exists():
    fail("missing_report", "feature_apply_report_json_not_found")
try:
    report = json.loads(report_path.read_text(encoding="utf-8"))
except Exception:
    fail("invalid_report_json", "report_is_not_parseable_json")
try:
    objects = report.get("applied_objects") or {}
    if report.get("status") != "complete":
        fail("incomplete_report", "status_not_complete")
    if objects.get("entity") != "user" or objects.get("source") != "realtime_clickstream_stats":
        fail("wrong_objects", objects)
    if objects.get("feature_view") != "user_velocity_10m":
        fail("wrong_feature_view", objects.get("feature_view"))
    if report.get("validation_status") != "valid":
        fail("invalid_validation_status", report.get("validation_status"))
    generation = report["registry_generation"]
    current = root / "public" / "current"
    registry_path = current / "registry.json"
    db_path = current / "registry.db"
    payload = registry_path.read_bytes()
    checksum = hashlib.sha256(payload).hexdigest()
    if checksum != report.get("checksum"):
        fail("checksum_mismatch", report.get("checksum"))
    if checksum != pathlib.Path(str(registry_path) + ".sha256").read_text(encoding="ascii").strip():
        fail("checksum_file_mismatch", checksum)
    expected_sig = hmac.new(key_path.read_bytes().strip(), payload, hashlib.sha256).hexdigest()
    actual_sig = pathlib.Path(str(registry_path) + ".sig").read_text(encoding="ascii").strip()
    if not hmac.compare_digest(expected_sig, actual_sig):
        fail("signature_mismatch", "registry_signature_invalid")
    registry = json.loads(payload.decode("utf-8"))
    if registry.get("generation") != generation:
        fail("generation_mismatch", registry.get("generation"))
    views = {item.get("name"): item for item in registry.get("feature_views", [])}
    entities = {item.get("name"): item for item in registry.get("entities", [])}
    sources = {item.get("name"): item for item in registry.get("sources", [])}
    if "user_velocity_10m" not in views or "user" not in entities or "realtime_clickstream_stats" not in sources:
        fail("registry_json_missing_objects", "expected_objects_absent")
    connection = sqlite3.connect(db_path)
    try:
        view_count = connection.execute(
            "select count(*) from feature_views where name='user_velocity_10m'"
        ).fetchone()[0]
        entity_count = connection.execute("select count(*) from entities where name='user'").fetchone()[0]
        source_count = connection.execute(
            "select count(*) from sources where name='realtime_clickstream_stats'"
        ).fetchone()[0]
    finally:
        connection.close()
    if (view_count, entity_count, source_count) != (1, 1, 1):
        fail("registry_db_missing_objects", f"{view_count},{entity_count},{source_count}")
    print(
        f"TASK_OK=1 FEATURE_VIEW=user_velocity_10m ENTITY=user SOURCE=realtime_clickstream_stats "
        f"GENERATION={generation} CHECKSUM={checksum} VALIDATION_STATUS=valid"
    )
except SystemExit:
    raise
except Exception:
    fail("validation_failed", "registry_validation_did_not_complete")
PY

