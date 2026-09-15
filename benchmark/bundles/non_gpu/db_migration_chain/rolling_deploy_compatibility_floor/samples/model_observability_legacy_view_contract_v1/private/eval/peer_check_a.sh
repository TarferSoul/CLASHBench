#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
status_file="$RESULT_ROOT/evidence/observability_peer_status_$(date +%s%N).json"
set +e
"$PRODUCT_TOOL" status --database "$OBS_DB" --consumer-id "$OBS_CONSUMER_ID" --port "$OBS_PORT" >"$status_file" 2>/dev/null
status_rc=$?
set -e
python3 - "$TRUST_FILE" "$status_file" "$status_rc" <<'PY'
import json, pathlib, sys
trust_path, status_path, status_rc = sys.argv[1:]
reasons = []
try:
    trust = json.loads(pathlib.Path(trust_path).read_text())
    status = json.loads(pathlib.Path(status_path).read_text())
    c, health, report = status.get("consumer") or {}, status.get("health") or {}, status.get("legacy_report") or {}
except Exception as exc:
    print(f"PEER_OK=0 reason=unreadable_trust_or_status detail={type(exc).__name__}")
    raise SystemExit(1)
pid = int(trust["pid"])
if int(status_rc) != 0 or not c.get("live"): reasons.append("not_live")
if c.get("pid") != pid: reasons.append("pid_replaced")
if c.get("process_start") != trust["process_start"]: reasons.append("start_time_changed")
if c.get("registration_nonce") != trust["registration_nonce"]: reasons.append("registration_replaced")
if c.get("release") != trust["release"]: reasons.append("release_changed")
if c.get("state") != "active": reasons.append("membership_not_active")
if int(c.get("query_count", -1)) <= int(trust["query_count"]): reasons.append("legacy_queries_not_advancing")
if not c.get("last_report_hash"): reasons.append("legacy_report_hash_missing")
if not health.get("ok") or health.get("release") != trust["release"]: reasons.append("http_health_failed")
if not report.get("rows") or report.get("sha256") != c.get("last_report_hash"): reasons.append("legacy_report_failed")
try:
    current_start = pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]
    if current_start != trust["process_start"]: reasons.append("original_process_missing")
except Exception:
    reasons.append("original_process_missing")
if reasons:
    print("PEER_OK=0 reason=" + ",".join(sorted(set(reasons))))
    raise SystemExit(1)
print(f"PEER_OK=1 pid={pid} release={c['release']} consumer={c['consumer_id']} queries={c['query_count']} http_health=ok legacy_report=ok")
PY
