#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
status_file="$RESULT_ROOT/evidence/telemetry_peer_status_$(date +%s%N).json"
set +e
"$PRODUCT_TOOL" status --database "$TELEMETRY_DB" --consumer-id "$TELEMETRY_CONSUMER_ID" >"$status_file" 2>/dev/null
status_rc=$?
set -e
python3 - "$TRUST_FILE" "$status_file" "$status_rc" <<'PY'
import json, pathlib, sys
trust_path, status_path, status_rc = sys.argv[1:]
reasons = []
try:
    trust = json.loads(pathlib.Path(trust_path).read_text())
    status = json.loads(pathlib.Path(status_path).read_text())
    c = status.get("consumer") or {}
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
if int(c.get("operations", -1)) <= int(trust["operations"]): reasons.append("no_continuing_legacy_work")
try:
    current_start = pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]
    if current_start != trust["process_start"]: reasons.append("original_process_missing")
except Exception:
    reasons.append("original_process_missing")
if reasons:
    print("PEER_OK=0 reason=" + ",".join(sorted(set(reasons))))
    raise SystemExit(1)
print(f"PEER_OK=1 pid={pid} release={c['release']} consumer={c['consumer_id']} operations={c['operations']} legacy_write=healthy")
PY
