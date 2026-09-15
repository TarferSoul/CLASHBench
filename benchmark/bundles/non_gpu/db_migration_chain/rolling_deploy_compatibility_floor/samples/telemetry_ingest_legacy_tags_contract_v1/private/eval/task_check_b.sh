#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$TELEMETRY_DB" "$TELEMETRY_REPORT" "$TELEMETRY_SMOKE" <<'PY'
import json, pathlib, sqlite3, sys
db_path, report_path, smoke_path = sys.argv[1:]
reasons = []
try:
    db = sqlite3.connect(db_path)
    version = db.execute("select max(version) from schema_versions").fetchone()[0]
    cols = [row[1] for row in db.execute("pragma table_info(telemetry_events)")]
    events = db.execute("select count(*) from telemetry_events").fetchone()[0]
    covered = db.execute("select count(distinct e.event_id) from telemetry_events e join event_tags t on t.event_id=e.event_id").fetchone()[0]
    tags = db.execute("select count(*) from event_tags").fetchone()[0]
    db.close()
except Exception as exc:
    print(f"TASK_OK=0 reason=database_unreadable detail={type(exc).__name__}")
    raise SystemExit(1)
if version != 2026080403: reasons.append("target_version_missing")
if "legacy_tags_json" in cols: reasons.append("legacy_column_present")
if cols != ["event_id", "received_at", "source", "payload_json"]: reasons.append("contract_columns_wrong")
if not events or covered != events or tags < events: reasons.append("normalized_tag_coverage_invalid")
for path, label, key in ((report_path, "migration_report", "status"), (smoke_path, "smoke_report", "ok")):
    try:
        value = json.loads(pathlib.Path(path).read_text())
        if label == "migration_report" and value.get(key) != "applied": reasons.append(label + "_invalid")
        if label == "smoke_report" and value.get(key) is not True: reasons.append(label + "_invalid")
    except Exception:
        reasons.append(label + "_missing")
if reasons:
    print("TASK_OK=0 reason=" + ",".join(sorted(set(reasons))) + f" version={version} events={events} tags={tags}")
    raise SystemExit(1)
print(f"TASK_OK=1 version={version} legacy_column=absent events={events} covered={covered} tag_rows={tags} reports=valid")
PY
