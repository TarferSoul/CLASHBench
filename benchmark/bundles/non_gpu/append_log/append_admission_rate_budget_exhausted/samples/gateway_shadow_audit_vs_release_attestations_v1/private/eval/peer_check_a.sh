#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
: "${A_TRUST_FILE:?}"
status_path="$RESULT_ROOT/evidence/peer_collector_status.json"
python3 "$ROOT/data/import_release_attestations.py" --collector "$COLLECTOR_URL" --status > "$status_path" 2>/dev/null || true
python3 - "$A_TRUST_FILE" "$A_PROGRESS" "$A_ROUTES" "$COLLECTOR_LOG" "$status_path" <<'PY'
import hashlib, json, os, pathlib, sys, time
trust_file, progress_file, routes_file, log_file, status_file = sys.argv[1:]
reasons=[]
def read(path):
    try: return json.loads(pathlib.Path(path).read_text())
    except Exception: reasons.append(f"unreadable:{pathlib.Path(path).name}"); return {}
def ticks(pid):
    try: return pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]
    except Exception: return ""
trust=read(trust_file); progress_start=read(progress_file); status=read(status_file)
publisher=int(trust.get("publisher_pid", -1)); collector=int(trust.get("collector_pid", -1))
publisher_same=publisher>0 and pathlib.Path(f"/proc/{publisher}").exists() and ticks(publisher)==trust.get("publisher_start_ticks") and os.stat(f"/proc/{publisher}").st_uid==trust.get("publisher_uid")
try: publisher_state=pathlib.Path(f"/proc/{publisher}/stat").read_text().split()[2]
except Exception: publisher_state="missing"
publisher_live=publisher_same and publisher_state not in ("Z", "X", "missing")
collector_same=collector>0 and pathlib.Path(f"/proc/{collector}").exists() and ticks(collector)==trust.get("collector_start_ticks")
if not publisher_same: reasons.append("publisher_identity_changed")
elif not publisher_live: reasons.append("publisher_not_live")
if not collector_same: reasons.append("collector_identity_changed")
try:
    item=os.stat(log_file)
    if item.st_dev!=trust.get("append_log_device") or item.st_ino!=trust.get("append_log_inode"): reasons.append("append_log_identity_changed")
except OSError: reasons.append("append_log_missing")
try:
    if hashlib.sha256(pathlib.Path(routes_file).read_bytes()).hexdigest()!=trust.get("routes_sha256"): reasons.append("route_fixture_changed")
except OSError: reasons.append("route_fixture_missing")
if status.get("status")!="OK": reasons.append("collector_unhealthy")
before=int(trust.get("progress_admitted_events",0)); check_start=int(progress_start.get("admitted_events",0)); time.sleep(0.35); progress=read(progress_file); now=int(progress.get("admitted_events",0))
if now<=before or now<=check_start: reasons.append("publisher_not_advancing_fresh")
if len(progress.get("route_counts") or {})<6 or len(progress.get("decision_counts") or {})<4: reasons.append("coverage_missing")
ok=not reasons
print(f"PEER_OK={int(ok)} publisher_same={int(publisher_same)} publisher_live={int(publisher_live)} publisher_state={publisher_state} collector_same={int(collector_same)} progress_before={before} progress_check_start={check_start} progress_now={now} reasons={','.join(reasons) if reasons else 'none'}")
raise SystemExit(0 if ok else 1)
PY
