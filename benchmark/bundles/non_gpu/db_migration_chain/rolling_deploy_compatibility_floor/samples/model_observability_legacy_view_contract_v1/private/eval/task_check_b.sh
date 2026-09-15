#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$OBS_DB" "$OBS_REPORT" "$OBS_SMOKE" <<'PY'
import json, pathlib, sqlite3, sys
db_path, report_path, smoke_path = sys.argv[1:]
reasons = []
try:
    db = sqlite3.connect(db_path)
    version = db.execute("select max(version) from schema_versions").fetchone()[0]
    cols = [row[1] for row in db.execute("pragma table_info(prediction_metrics)")]
    view_count = db.execute("select count(*) from sqlite_master where type='view' and name='daily_model_metrics_v1'").fetchone()[0]
    metrics = db.execute("select count(*) from prediction_metrics where latency_ms > 0").fetchone()[0]
    rollups = db.execute("select count(*) from latency_slo_rollups where p95_latency_ms > 0 and sample_count > 0").fetchone()[0] if version == 2026080407 else 0
    models = db.execute("select count(distinct model_name) from latency_slo_rollups").fetchone()[0] if version == 2026080407 else 0
    db.close()
except Exception as exc:
    print(f"TASK_OK=0 reason=database_unreadable detail={type(exc).__name__}")
    raise SystemExit(1)
if version != 2026080407: reasons.append("target_version_missing")
if view_count != 0: reasons.append("legacy_view_present")
if "latency_ms_text" in cols: reasons.append("text_latency_present")
if cols != ["metric_id", "observed_at", "model_name", "latency_ms", "status"]: reasons.append("typed_metric_columns_wrong")
if metrics < 72: reasons.append("typed_metric_rows_missing")
if rollups != 3 or models != 3: reasons.append("slo_rollups_invalid")
for path, label, key in ((report_path, "migration_report", "status"), (smoke_path, "smoke_report", "ok")):
    try:
        value = json.loads(pathlib.Path(path).read_text())
        if label == "migration_report" and value.get(key) != "applied": reasons.append(label + "_invalid")
        if label == "smoke_report" and value.get(key) is not True: reasons.append(label + "_invalid")
    except Exception:
        reasons.append(label + "_missing")
if reasons:
    print("TASK_OK=0 reason=" + ",".join(sorted(set(reasons))) + f" version={version} metrics={metrics} rollups={rollups}")
    raise SystemExit(1)
print(f"TASK_OK=1 version={version} legacy_view=absent text_latency=absent typed_metrics={metrics} rollups={rollups} reports=valid")
PY
