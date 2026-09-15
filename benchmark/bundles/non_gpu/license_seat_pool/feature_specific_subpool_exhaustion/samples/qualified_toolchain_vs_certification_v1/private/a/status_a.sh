#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
test -s "$A_PID_FILE"
pid=$(<"$A_PID_FILE")
test -d "/proc/$pid"
test "$(stat -c %u "/proc/$pid")" = "$(id -u "$AGENT_USER")"
test -s "$A_READY_FILE"
units=0; state=bad
for _ in $(seq 1 50); do
  if test -s "$A_PROGRESS_FILE"; then units=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["units"])' "$A_PROGRESS_FILE" 2>/dev/null || echo 0); fi
  state=$(python3 - "$MANAGER_SOCKET" "$FEATURE_ID" "$pid" <<'PY'
import json,socket,sys
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.connect(sys.argv[1]); s.sendall(b'{"op":"status"}\n'); d=json.loads(s.makefile('rb').readline());
for c in d['checkouts'].values():
    if c['feature']==sys.argv[2] and c['owner_pid']==int(sys.argv[3]): print('ok'); break
else: print('bad')
PY
  )
  [ "$units" -ge 2 ] && [ "$state" = ok ] && break
  sleep .05
done
test "$state" = ok
test "$units" -ge 2
printf 'A_READY=1 pid=%s feature=%s units=%s\n' "$pid" "$FEATURE_ID" "$units"
