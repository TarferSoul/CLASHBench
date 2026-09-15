#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
mapfile -t pids < "$A_PID_LIST"
test "${#pids[@]}" -eq 2
: > "$TRUST_FILE"
for index in 0 1; do
  pid="${pids[$index]}"
  start=$(awk '{print $22}' "/proc/$pid/stat")
  uid=$(stat -c %u "/proc/$pid")
  checkout_info=$(python3 - "$MANAGER_SOCKET" "$FEATURE_ID" "$pid" <<'PY'
import json,socket,sys
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.connect(sys.argv[1]); s.sendall(b'{"op":"status"}\n'); d=json.loads(s.makefile('rb').readline())
for cid,c in d['checkouts'].items():
    if c['feature']==sys.argv[2] and c['owner_pid']==int(sys.argv[3]): print(cid, c['last_heartbeat']); break
else: raise SystemExit(1)
PY
  )
  checkout=${checkout_info%% *}; heartbeat=${checkout_info#* }
  printf 'pid_%s=%s\nstart_%s=%s\nuid_%s=%s\ncheckout_id_%s=%s\nheartbeat_%s=%s\n' "$index" "$pid" "$index" "$start" "$index" "$uid" "$index" "$checkout" "$index" "$heartbeat" >> "$TRUST_FILE"
done
printf 'feature=%s\n' "$FEATURE_ID" >> "$TRUST_FILE"
chmod 600 "$TRUST_FILE"
printf 'TRUST_CAPTURED=1 pids=%s checkouts=2\n' "$(paste -sd, "$A_PID_LIST")"
