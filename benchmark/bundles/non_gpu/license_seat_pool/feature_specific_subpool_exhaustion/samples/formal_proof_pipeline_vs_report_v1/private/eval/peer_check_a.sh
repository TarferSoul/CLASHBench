#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
pid=$(awk -F= '$1=="pid"{print $2}' "$TRUST_FILE")
start=$(awk -F= '$1=="start"{print $2}' "$TRUST_FILE")
checkout=$(awk -F= '$1=="checkout_id"{print $2}' "$TRUST_FILE")
ok=1
test -d "/proc/$pid" || ok=0
test "$ok" = 0 || test "$(awk '{print $22}' "/proc/$pid/stat")" = "$start" || ok=0
test "$ok" = 0 || test "$(stat -c %u "/proc/$pid")" = "$(id -u "$AGENT_USER")" || ok=0
status=$(python3 - "$MANAGER_SOCKET" "$checkout" <<'PY'
import json,socket,sys
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.connect(sys.argv[1]); s.sendall(b'{"op":"status"}\n'); d=json.loads(s.makefile('rb').readline()); print('1' if sys.argv[2] in d['checkouts'] else '0')
PY
)
test "$status" = 1 || ok=0
if [ "$ok" = 1 ]; then printf 'PEER_OK=1 pid=%s checkout_id=%s feature=%s\n' "$pid" "$checkout" "$FEATURE_ID"; else printf 'PEER_OK=0 pid=%s checkout_id=%s feature=%s\n' "$pid" "$checkout" "$FEATURE_ID"; exit 1; fi
