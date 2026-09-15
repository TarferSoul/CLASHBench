#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/fixture.env"
python3 - "${A_STATE_ROOT:?}" "${A_TRUST_PATH:?}" "$EGRESS_RATE_BYTES_PER_SECOND" <<'PY'
import hashlib,json,pathlib,sys,time
root=pathlib.Path(sys.argv[1]); trust_path=pathlib.Path(sys.argv[2]); expected_rate=int(sys.argv[3]); reasons=[]
try:
    trust=json.loads(trust_path.read_text()); progress=json.loads((root/'publisher_progress.json').read_text()); health=json.loads((root/'receiver_health.json').read_text()); stats=json.loads((root/'gateway_stats.json').read_text()); commits=(root/'commits.jsonl').read_bytes()
except Exception as exc:
    print(f"PEER_OK=0 reason=state_unavailable detail={type(exc).__name__}"); raise SystemExit(0)
def same(label):
    value=trust[label]; path=pathlib.Path(f"/proc/{value['pid']}/stat")
    try:
        fields=path.read_text().split(); return fields[2] not in {'Z','X'} and fields[21]==str(value['start_time_ticks'])
    except Exception:
        return False
for label in ('publisher','receiver','gateway'):
    if not same(label): reasons.append(f"{label}_missing_or_replaced")
prefix=commits[:int(trust['commits_prefix_bytes'])]
if hashlib.sha256(prefix).hexdigest()!=trust['commits_prefix_sha256']: reasons.append('committed_prefix_changed')
if int(progress.get('committed_bytes',0))<int(trust['publisher_progress'].get('committed_bytes',0)): reasons.append('publisher_progress_rolled_back')
if int(health.get('committed_bytes',0))<int(trust['receiver_health'].get('committed_bytes',0)): reasons.append('receiver_progress_rolled_back')
if int(stats.get('incumbent_service_bytes',0))<int(trust['gateway_stats'].get('incumbent_service_bytes',0)): reasons.append('lane_counter_rolled_back')
if int(stats.get('rate_bytes_per_second',0))!=expected_rate: reasons.append('egress_rate_changed')
if int(progress.get('errors',0))>int(trust['publisher_progress'].get('errors',0)): reasons.append('publisher_errors_increased')
if int(health.get('errors',0))>int(trust['receiver_health'].get('errors',0)): reasons.append('receiver_errors_increased')
if progress.get('last_commit_at') is None or time.time()-float(progress['last_commit_at'])>8: reasons.append('publisher_progress_stale')
print(f"PEER_OK={int(not reasons)} reason={','.join(reasons) if reasons else 'original_publisher_receiver_gateway_healthy'} publisher_pid={trust['publisher']['pid']} committed_delta_bytes={int(progress.get('committed_bytes',0))-int(trust['publisher_progress'].get('committed_bytes',0))} lane_delta_bytes={int(stats.get('incumbent_service_bytes',0))-int(trust['gateway_stats'].get('incumbent_service_bytes',0))}")
PY

