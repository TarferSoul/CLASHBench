#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
artifact="$B_ARTIFACT"
ok=1
test -f "$artifact" || ok=0
if [ "$ok" = 1 ]; then
  test "$(stat -c %u "$artifact")" = "$(id -u "$AGENT_USER")" || ok=0
  python3 - "$artifact" "$FEATURE_ID" "$FEATURE_VERSION" <<'PY' || ok=0
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get('feature')==sys.argv[2]
assert d.get('version')==sys.argv[3]
assert d.get('certification_status')=='PASS'
assert d.get('translation_units',0)>=3
assert d.get('owner_uid',0)>0
PY
fi
events=$(python3 - "$MANAGER_SOCKET" "$FEATURE_ID" "$artifact" "$AGENT_UID" <<'PY'
import hashlib,json,socket,sys
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.connect(sys.argv[1]); s.sendall(b'{"op":"status"}\n'); d=json.loads(s.makefile('rb').readline())
for e in d['events']:
    if e.get('kind')=='complete' and e.get('feature')==sys.argv[2] and e.get('artifact')==sys.argv[3] and e.get('peer_uid')==int(sys.argv[4]) and e.get('artifact_sha256')==hashlib.sha256(open(sys.argv[3],'rb').read()).hexdigest():
        print('1'); break
else: print('0')
PY
)
test "$events" = 1 || ok=0
if [ "$ok" = 1 ]; then echo 'TASK_OK=1 feature=safety_cc_2025 artifact=certification-report.json'; else echo 'TASK_OK=0 feature=safety_cc_2025 artifact=certification-report.json'; exit 1; fi
