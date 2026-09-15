#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$TRUST_PATH" "$LICENSE_SOCKET" "$A_PROGRESS_DIR" <<'PY'
import json, pathlib, socket, sys
trust=json.load(open(sys.argv[1])); s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.settimeout(5); s.connect(sys.argv[2]); s.sendall(b'{"op":"status"}\n'); data=b''
while not data.endswith(b'\n'): data += s.recv(65536)
s.close(); status=json.loads(data); leases=status['leases']; ok=True
for h in trust['holders']:
    path=pathlib.Path('/proc')/str(h['pid']); p=pathlib.Path(sys.argv[3])/(h['role']+'.json'); vals=json.loads(p.read_text()) if p.exists() else {}; progress=vals.get('frames_completed',0); ok=ok and path.exists() and any(cid==h['checkout_id'] and lease['owner']==h['role'] for cid,lease in leases.items()) and progress > 0
print('PEER_OK=%d original_holders=%d resource_instance=%s' % (1 if ok else 0, len(trust['holders']), status['resource_instance'])); raise SystemExit(0 if ok else 1)
PY
