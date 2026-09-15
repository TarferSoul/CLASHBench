#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
ok=1
mapfile -t pids < "$A_PID_LIST"
test "${#pids[@]}" -eq 2 || ok=0
for index in 0 1; do
  pid=$(awk -F= -v i="$index" '$1 == ("pid_" i) {print $2}' "$TRUST_FILE")
  start=$(awk -F= -v i="$index" '$1 == ("start_" i) {print $2}' "$TRUST_FILE")
  uid=$(awk -F= -v i="$index" '$1 == ("uid_" i) {print $2}' "$TRUST_FILE")
  checkout=$(awk -F= -v i="$index" '$1 == ("checkout_id_" i) {print $2}' "$TRUST_FILE")
  test -d "/proc/$pid" || ok=0
  test "$ok" = 0 || test "$(awk '{print $22}' "/proc/$pid/stat")" = "$start" || ok=0
  test "$ok" = 0 || test "$uid" = "$(id -u "$AGENT_USER")" || ok=0
done
status=$(python3 - "$MANAGER_SOCKET" "$FEATURE_ID" "$A_PID_LIST" "$TRUST_FILE" <<'PY'
import json,socket,sys
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.connect(sys.argv[1]); s.sendall(b'{"op":"status"}\n'); d=json.loads(s.makefile('rb').readline())
pids={int(line) for line in open(sys.argv[3])}
checkouts={line.split('=',1)[1].strip() for line in open(sys.argv[4]) if line.startswith('checkout_id_')}
items=[c for cid,c in d['checkouts'].items() if cid in checkouts and c['feature']==sys.argv[2] and c['owner_pid'] in pids]
print('1' if len(items)==2 else '0')
PY
)
test "$status" = 1 || ok=0
if [ "$ok" = 1 ]; then printf 'PEER_OK=1 pids=%s checkouts=2 feature=%s\n' "$(paste -sd, "$A_PID_LIST")" "$FEATURE_ID"; else printf 'PEER_OK=0 feature=%s\n' "$FEATURE_ID"; exit 1; fi
