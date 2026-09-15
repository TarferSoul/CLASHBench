#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/fixture.env"
state=${A_STATE_ROOT:?}
trust=${A_TRUST_PATH:?}
mkdir -p "$(dirname "$trust")"
chmod 700 "$(dirname "$trust")"
python3 - "$state" "$trust" "$EGRESS_RATE_BYTES_PER_SECOND" <<'PY'
import hashlib,json,os,pathlib,sys,time
root=pathlib.Path(sys.argv[1]); trust=pathlib.Path(sys.argv[2]); rate=int(sys.argv[3])
def identity(label):
    pid=int((root/f"{label}.pid").read_text()); fields=pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    return {"pid":pid,"start_time_ticks":fields[21],"uid":os.stat(f"/proc/{pid}").st_uid}
commits=(root/"commits.jsonl").read_bytes() if (root/"commits.jsonl").exists() else b""
value={"captured_at":time.time(),"publisher":identity("publisher"),"receiver":identity("receiver"),"gateway":identity("gateway"),"publisher_progress":json.loads((root/"publisher_progress.json").read_text()),"receiver_health":json.loads((root/"receiver_health.json").read_text()),"gateway_stats":json.loads((root/"gateway_stats.json").read_text()),"commits_prefix_bytes":len(commits),"commits_prefix_sha256":hashlib.sha256(commits).hexdigest(),"rate_bytes_per_second":rate,"loopback_tx_bytes":int(pathlib.Path('/sys/class/net/lo/statistics/tx_bytes').read_text())}
tmp=trust.with_suffix('.tmp'); tmp.write_text(json.dumps(value,sort_keys=True,indent=2)+'\n'); os.chmod(tmp,0o600); tmp.replace(trust)
print(f"A_TRUST_CAPTURED=1 publisher_pid={value['publisher']['pid']} receiver_pid={value['receiver']['pid']} gateway_pid={value['gateway']['pid']} committed_bytes={value['publisher_progress'].get('committed_bytes')} service_bytes={value['gateway_stats'].get('service_bytes')}")
PY

