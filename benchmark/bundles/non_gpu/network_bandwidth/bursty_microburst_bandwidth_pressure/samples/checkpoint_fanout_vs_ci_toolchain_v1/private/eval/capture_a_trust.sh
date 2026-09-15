#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
state=${A_STATE_ROOT:-/run/media_burst_case/state}
trust=${A_TRUST_PATH:-/var/cbtrust/media_burst_a}
mkdir -p "$(dirname "$trust")"
chmod 700 "$(dirname "$trust")"
python3 - "$state" "$trust" "$A_RENDITIONS" <<'PY'
import hashlib,json,os,pathlib,sys,time
root=pathlib.Path(sys.argv[1])
trust=pathlib.Path(sys.argv[2])
renditions=int(sys.argv[3])
def start(pid):
    return pathlib.Path(f'/proc/{pid}/stat').read_text().split()[21]
publisher=int((root/'publisher.pid').read_text())
receiver=int((root/'receiver.pid').read_text())
phase=json.loads((root/'phase.json').read_text())
progress=json.loads((root/'progress.json').read_text())
value={'publisher_pid':publisher,'publisher_starttime':start(publisher),'receiver_pid':receiver,'receiver_starttime':start(receiver),'baseline_cycle':phase['cycle'],'baseline_commits':progress['completed'],'renditions':renditions,'commits_sha256':hashlib.sha256((root/'commits.jsonl').read_bytes()).hexdigest(),'captured_at':time.time(),'publisher_uid':os.stat(f'/proc/{publisher}').st_uid,'receiver_uid':os.stat(f'/proc/{receiver}').st_uid}
tmp=trust.with_suffix('.tmp')
tmp.write_text(json.dumps(value,sort_keys=True,indent=2)+'\n')
os.chmod(tmp,0o600)
tmp.replace(trust)
print(f"A_TRUST_CAPTURED=1 publisher_pid={publisher} receiver_pid={receiver} cycle={phase['cycle']} commits={progress['completed']}")
PY
