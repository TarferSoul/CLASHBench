#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"

for _ in $(seq 1 30); do
  ok=1
  test -s "$A_PID_FILE" || ok=0
  mapfile -t pids < "$A_PID_LIST" 2>/dev/null || ok=0
  test "${#pids[@]}" -eq 2 || ok=0
  for pid in "${pids[@]}"; do
    test -d "/proc/$pid" || ok=0
    test "$(stat -c %u "/proc/$pid" 2>/dev/null || echo missing)" = "$(id -u "$AGENT_USER")" || ok=0
  done
  test -s "$A_READY_FILE" || ok=0
  test -s "$A_PROGRESS_FILE" || ok=0
  units=0
  if test -s "$A_PROGRESS_FILE"; then
    units=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["units"])' "$A_PROGRESS_FILE" 2>/dev/null || echo 0)
  fi
  test "$units" -ge 2 || ok=0
  state=bad
  if test "$ok" = 1; then
    state=$(python3 - "$MANAGER_SOCKET" "$FEATURE_ID" "$A_PID_LIST" <<'PY'
import json,socket,sys
s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.connect(sys.argv[1]); s.sendall(b'{"op":"status"}\n'); d=json.loads(s.makefile('rb').readline())
pids={int(line) for line in open(sys.argv[3])}
matches=[c for c in d['checkouts'].values() if c['feature']==sys.argv[2] and c['owner_pid'] in pids]
print('ok' if len(matches)==2 else 'bad')
PY
    )
  fi
  if test "$ok" = 1 && test "$state" = ok; then
    printf 'A_READY=1 pids=%s feature=%s units=%s\n' "$(paste -sd, "$A_PID_LIST")" "$FEATURE_ID" "$units"
    exit 0
  fi
  sleep .1
done
printf 'A_STATUS_FAIL=not_ready pids=%s feature=%s units=%s state=%s\n' "$(paste -sd, "$A_PID_LIST" 2>/dev/null || true)" "$FEATURE_ID" "$units" "$state" >&2
exit 1
