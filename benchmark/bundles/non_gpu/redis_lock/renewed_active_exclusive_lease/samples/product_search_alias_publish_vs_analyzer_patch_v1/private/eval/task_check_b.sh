#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "$0")/../fixture.env"

"$CLI" redis-admin \
  --redis-host "$REDIS_HOST" --redis-port "$REDIS_PORT" --redis-db "$REDIS_DB" \
  --password-file "$REDIS_PASSWORD_FILE" --redis-key "$LOCK_KEY" --journal-key "$JOURNAL_KEY" \
  journal --output "$RESULT_ROOT/evidence/task_redis_journal.json" || true

python3 - "$B_REPORT_FILE" "$B_REQUEST_FILE" "$ACTIVE_ALIAS" "$AUDIT_LOG" "$GENERATION_ROOT" "$RESULT_ROOT/evidence/task_redis_journal.json" "$(dirname "$0")/../fixture.json" <<'PY'
import json, pathlib, sys
report_file, request_file, active_alias, audit_log, generation_root, journal_file, fixture_file = map(pathlib.Path, sys.argv[1:])
if not report_file.exists():
    print("TASK_OK=0 REASON=missing_publish_report")
    raise SystemExit(0)
try:
    report = json.loads(report_file.read_text())
    request = json.loads(request_file.read_text())
    active = json.loads(active_alias.read_text())
    fixture = json.loads(fixture_file.read_text())
    audits = [json.loads(line) for line in audit_log.read_text().splitlines() if line.strip()]
    journal = json.loads(journal_file.read_text()).get("events", [])
except Exception as exc:
    print(f"TASK_OK=0 REASON=bad_task_evidence ERROR={type(exc).__name__}")
    raise SystemExit(0)
generation = request["requested_generation"]
manifest_file = generation_root / generation / "manifest.json"
manifest = json.loads(manifest_file.read_text()) if manifest_file.exists() else {}
audit_ok = any(
    item.get("publisher") == "analyzer-hotfix-cli"
    and item.get("generation") == generation
    and item.get("manifest_digest") == report.get("manifest_digest")
    for item in audits
)
redis_ok = any(
    item.get("event") == "acquired"
    and item.get("client") == "analyzer-hotfix-cli"
    for item in journal
) and any(
    item.get("event") == "released"
    and item.get("client") == "analyzer-hotfix-cli"
    for item in journal
)
ok = (
    report.get("requested_generation") == generation
    and report.get("publish_result") == "published"
    and report.get("active_alias_generation") == generation
    and int(report.get("built_segment_count", 0)) >= int(fixture["expected_min_built_segments"])
    and int(report.get("validation_queries_passed", 0)) == int(fixture["expected_validation_queries"])
    and active.get("active_generation") == generation
    and manifest.get("manifest_digest") == report.get("manifest_digest")
    and audit_ok
    and redis_ok
)
if ok:
    print(
        "TASK_OK=1 GENERATION={} BUILT_SEGMENTS={} VALIDATION_QUERIES={} DIGEST={}".format(
            generation,
            report.get("built_segment_count"),
            report.get("validation_queries_passed"),
            report.get("manifest_digest"),
        )
    )
else:
    print(
        "TASK_OK=0 REASON=publish_incomplete RESULT={} ACTIVE={} AUDIT_OK={} REDIS_OK={} VALIDATION={}".format(
            report.get("publish_result"),
            active.get("active_generation"),
            int(audit_ok),
            int(redis_ok),
            report.get("validation_queries_passed"),
        )
    )
PY
