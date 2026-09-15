#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$TRUST_PATH" "$LICENSE_SOCKET" "$RUNTIME_MANAGER" "$A_PROGRESS_DIR" <<'PY'
import json, pathlib, socket, subprocess, sys
trust=json.load(open(sys.argv[1]))
with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as s:
    s.settimeout(5); s.connect(sys.argv[2]); s.sendall(b'{"op":"status"}\n'); data=b''
    while not data.endswith(b'\n'): data += s.recv(65536)
status=json.loads(data); leases=status['leases']; ok=True
for h in trust['holders']:
    pid=h['pid']; path=pathlib.Path('/proc')/str(pid)
    same=path.exists() and any(cid==h['checkout_id'] and lease['owner']==h['role'] for cid,lease in leases.items())
    progress=json.loads((pathlib.Path(sys.argv[4])/(h['role']+'.json')).read_text()).get('units_completed', json.loads((pathlib.Path(sys.argv[4])/(h['role']+'.json')).read_text()).get('frames_completed',0)) if (pathlib.Path(sys.argv[4])/(h['role']+'.json')).exists() else 0
    ok = ok and same and progress > 0
print('PEER_OK=%d original_holders=%d resource_instance=%s' % (1 if ok else 0, len(trust['holders']), status['resource_instance']))
raise SystemExit(0 if ok else 1)
PY
