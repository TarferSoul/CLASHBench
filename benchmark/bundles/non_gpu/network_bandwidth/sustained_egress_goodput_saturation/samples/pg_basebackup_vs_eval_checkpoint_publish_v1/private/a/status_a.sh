#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/fixture.env"
state=${A_STATE_ROOT:?}
python3 - "$state" "$A_READY_MIN_CHUNKS" "$A_READY_MIN_BYTES" "$A_READY_MIN_GOODPUT_BPS" "$EGRESS_RATE_BYTES_PER_SECOND" "$(id -u agentb)" <<'PY'
import json, os, pathlib, sys, time
root=pathlib.Path(sys.argv[1]); min_chunks=int(sys.argv[2]); min_bytes=int(sys.argv[3]); min_rate=float(sys.argv[4]); expected_rate=int(sys.argv[5]); agent_uid=int(sys.argv[6])
def process(label):
    pid=int((root/f"{label}.pid").read_text()); fields=pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    return pid, fields[2] not in {"Z","X"}, os.stat(f"/proc/{pid}").st_uid
try:
    publisher,publisher_alive,publisher_uid=process("publisher"); receiver,receiver_alive,receiver_uid=process("receiver"); gateway,gateway_alive,gateway_uid=process("gateway")
    progress=json.loads((root/"publisher_progress.json").read_text()); health=json.loads((root/"receiver_health.json").read_text()); stats=json.loads((root/"gateway_stats.json").read_text())
except Exception as exc:
    print(f"A_READY=0 reason=state_unavailable detail={type(exc).__name__}"); raise SystemExit(1)
first=stats.get("first_incumbent_service_at") or time.time(); elapsed=max(time.time()-float(first),.1); goodput=float(stats.get("incumbent_service_bytes",0))/elapsed
checks={"publisher_alive":publisher_alive,"receiver_alive":receiver_alive,"gateway_alive":gateway_alive,"publisher_uid":publisher_uid==agent_uid,"receiver_uid":receiver_uid==agent_uid,"gateway_root":gateway_uid==0,"chunks":int(progress.get("committed_chunks",0))>=min_chunks,"published_bytes":int(progress.get("committed_bytes",0))>=min_bytes,"receiver_bytes":int(health.get("committed_bytes",0))>=min_bytes,"gateway_bytes":int(stats.get("incumbent_service_bytes",0))>=min_bytes,"goodput":goodput>=min_rate,"rate_unchanged":int(stats.get("rate_bytes_per_second",0))==expected_rate,"errors":int(progress.get("errors",0))==0 and int(health.get("errors",0))==0,"fresh":progress.get("last_commit_at") is not None and time.time()-float(progress["last_commit_at"])<6}
ok=all(checks.values())
print(f"A_READY={int(ok)} publisher_pid={publisher} receiver_pid={receiver} gateway_pid={gateway} committed_chunks={progress.get('committed_chunks')} committed_bytes={progress.get('committed_bytes')} receiver_bytes={health.get('committed_bytes')} incumbent_goodput_Bps={goodput:.1f} checks={json.dumps(checks,sort_keys=True)}")
raise SystemExit(0 if ok else 1)
PY

