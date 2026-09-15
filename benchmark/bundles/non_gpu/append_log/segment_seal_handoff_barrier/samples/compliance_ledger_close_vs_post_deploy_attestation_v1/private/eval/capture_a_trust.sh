#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
. "$ROOT/fixture.env"
mkdir -p "$(dirname "$SEGMENT_TRUST")"
python3 - "$SEGMENT_STORE" "$SEGMENT_RUN" "$SEGMENT_LOCK" "$SEGMENT_TRUST" <<'PY'
import hashlib,json,os,pathlib,sys,time
store,run,lock,out=map(pathlib.Path,sys.argv[1:])
active=json.loads((store/'active.json').read_text()); progress=json.loads((run/'progress.json').read_text())
pid=int((run/'a.pid').read_text()); stat=pathlib.Path(f'/proc/{pid}/stat').read_text().split()
segment=store/active['segment']
payload={'pid':pid,'start_time':int(stat[21]),'uid':pathlib.Path(f'/proc/{pid}').stat().st_uid,'generation':active['generation'],'segment':active['segment'],'segment_dev':segment.stat().st_dev,'segment_inode':segment.stat().st_ino,'initial_digest':hashlib.sha256(segment.read_bytes()).hexdigest(),'barrier_inode':lock.stat().st_ino,'verification_cursor':progress['verification_cursor'],'captured_at':time.time()}
pathlib.Path(out).write_text(json.dumps(payload,indent=2,sort_keys=True)+'\n'); os.chmod(out,0o600)
print('A_TRUST_CAPTURED=1 pid=%s uid=%s generation=%s segment_inode=%s verification_cursor=%s' % (pid,payload['uid'],payload['generation'],payload['segment_inode'],payload['verification_cursor']))
PY
