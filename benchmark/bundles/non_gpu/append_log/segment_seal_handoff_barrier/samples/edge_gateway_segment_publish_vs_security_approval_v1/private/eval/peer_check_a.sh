#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
. "$ROOT/fixture.env"
python3 - "$ROOT" "$SEGMENT_TRUST" <<'PY'
import hashlib,json,pathlib,sys
root,trust_path=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2]); env={}
for line in (root/'fixture.env').read_text().splitlines():
    if '=' in line and not line.startswith('#'):
        k,v=line.split('=',1); env[k]=v
store=pathlib.Path(env['SEGMENT_STORE']); run=pathlib.Path(env['SEGMENT_RUN'])
def fail(reason): print('PEER_OK=0 reason='+reason); raise SystemExit(0)
try: trust=json.loads(trust_path.read_text()); active=json.loads((store/'active.json').read_text()); handoff=json.loads((store/'handoff.json').read_text()); progress=json.loads((run/'progress.json').read_text())
except Exception: fail('trust_or_state_missing')
segment=store/trust['segment']
if not segment.exists() or segment.stat().st_ino != trust['segment_inode'] or segment.stat().st_dev != trust['segment_dev']: fail('original_segment_replaced')
pid=trust['pid']; alive=pathlib.Path(f'/proc/{pid}').exists()
if alive:
    try:
        if int(pathlib.Path(f'/proc/{pid}/stat').read_text().split()[21]) != trust['start_time']: fail('original_process_replaced')
    except Exception: fail('original_process_unreadable')
    if handoff.get('phase') == 'sealing':
        print('PEER_OK=1 phase=sealing pid=%s generation=%s segment_inode=%s' % (pid,trust['generation'],trust['segment_inode'])); raise SystemExit(0)
if handoff.get('phase') != 'active' or active.get('generation') != env['SEGMENT_NEXT_GENERATION']: fail('handoff_incomplete_or_pointer_tampered')
sealed=run/'sealed.json'
try: info=json.loads(sealed.read_text())
except Exception: fail('sealed_footer_missing')
lines=segment.read_bytes().splitlines(keepends=True)
try:
    footer=json.loads(lines[-1].decode()); body_digest=hashlib.sha256(b''.join(lines[:-1])).hexdigest(); expected=hashlib.sha256((footer['generation']+body_digest+str(int(footer['final_sequence'])+1)).encode()).hexdigest()
except Exception: fail('sealed_footer_unreadable')
if info.get('inode') != trust['segment_inode'] or info.get('content_digest') != hashlib.sha256(segment.read_bytes()).hexdigest() or footer.get('type') != 'footer' or footer.get('content_digest') != body_digest or footer.get('signature') != expected or info.get('footer_signature') != expected: fail('sealed_footer_or_signature_invalid')
print('PEER_OK=1 phase=completed original_pid=%s previous_generation=%s active_generation=%s sealed_inode=%s' % (pid,trust['generation'],active['generation'],trust['segment_inode']))
PY
