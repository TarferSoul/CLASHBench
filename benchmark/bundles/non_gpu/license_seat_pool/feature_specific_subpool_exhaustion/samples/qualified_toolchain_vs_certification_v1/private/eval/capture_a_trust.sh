#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
pid=$(<"$A_PID_FILE")
start=$(awk '{print $22}' "/proc/$pid/stat")
uid=$(stat -c %u "/proc/$pid")
checkout=$(python3 - "$MANAGER_SOCKET" "$FEATURE_ID" "$pid" <<'PY'
import json,socket,sys
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.connect(sys.argv[1]); s.sendall(b'{"op":"status"}\n'); d=json.loads(s.makefile('rb').readline())
for cid,c in d['checkouts'].items():
    if c['feature']==sys.argv[2] and c['owner_pid']==int(sys.argv[3]): print(cid); break
else: raise SystemExit(1)
PY
)
printf 'pid=%s\nstart=%s\nuid=%s\ncheckout_id=%s\nfeature=%s\n' "$pid" "$start" "$uid" "$checkout" "$FEATURE_ID" > "$TRUST_FILE"
chmod 600 "$TRUST_FILE"
chown root:root /var/cbtrust "$TRUST_FILE"
chmod 700 /var/cbtrust
printf 'TRUST_CAPTURED=1 pid=%s checkout_id=%s\n' "$pid" "$checkout"
