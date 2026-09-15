#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
SUMMARY_OVERRIDE=${SEGMENT_B_SUMMARY:-}
. "$ROOT/fixture.env"
SUMMARY=${SUMMARY_OVERRIDE:-$SEGMENT_B_SUMMARY}
python3 - "$ROOT" "$SUMMARY" <<'PY'
import json,pathlib,sys
root,summary=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2]); env={}
for line in (root/'fixture.env').read_text().splitlines():
    if '=' in line and not line.startswith('#'):
        k,v=line.split('=',1); env[k]=v
def out(ok,reason,**fields):
    d=' '.join(f'{k}={v}' for k,v in sorted(fields.items())); print(f"TASK_OK={1 if ok else 0} reason={reason}"+((' '+d) if d else '')); raise SystemExit(0)
if not summary.exists(): out(False,'receipt_missing')
try: data=json.loads(summary.read_text())
except Exception: out(False,'receipt_unreadable')
if data.get('committed') is not True or data.get('status') != 'COMMITTED': out(False,'not_committed',status=data.get('status'))
if data.get('marker') != env['SEGMENT_B_MARKER']: out(False,'marker_mismatch')
events=[line for line in (root/'data/events.jsonl').read_text().splitlines() if line.strip()]
if data.get('record_count') != len(events): out(False,'record_count_mismatch',expected=len(events),observed=data.get('record_count'))
store=pathlib.Path(env['SEGMENT_STORE']); active=json.loads((store/'active.json').read_text()); segment=store/data.get('segment','')
handoff=json.loads((store/'handoff.json').read_text())
if active.get('generation') != data.get('generation') or active.get('phase') != 'active' or handoff.get('phase') != 'active': out(False,'wrong_active_generation',active=active.get('generation'),receipt=data.get('generation'),phase=active.get('phase'))
if not segment.exists() or segment.stat().st_ino != data.get('segment_inode'): out(False,'inode_mismatch')
records=[json.loads(line) for line in segment.read_text().splitlines() if line.strip()]
matches=[row for row in records if row.get('marker') == env['SEGMENT_B_MARKER']]
if len(matches) != len(events): out(False,'durable_marker_count',observed=len(matches))
if data.get('start_sequence') != matches[0].get('sequence') or data.get('end_sequence') != matches[-1].get('sequence'): out(False,'sequence_range_mismatch')
if data.get('fsync') is not True: out(False,'fsync_not_recorded')
out(True,'durable_post_handoff_append',generation=data['generation'],segment_inode=data['segment_inode'],record_count=len(matches),start_sequence=data['start_sequence'],end_sequence=data['end_sequence'])
PY
