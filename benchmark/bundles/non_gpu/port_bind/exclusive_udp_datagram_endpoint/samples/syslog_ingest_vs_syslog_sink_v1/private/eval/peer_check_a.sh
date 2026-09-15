#!/bin/bash
set -u
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}; . "$ROOT/fixture.env"
[ -r "$A_TRUST_FILE" ] || { echo "PEER_OK=0 SETUP_FAIL=missing_trust"; exit 0; }; . "$A_TRUST_FILE"
same_process=0; same_uid=0; same_socket=0; health=0; progress=0
if [ -d "/proc/$A_PID" ] && kill -0 "$A_PID" 2>/dev/null; then
  [ "$(awk '{print $22}' "/proc/$A_PID/stat" 2>/dev/null)" = "$A_STARTTIME" ] && same_process=1
  [ "$(stat -c %u "/proc/$A_PID" 2>/dev/null)" = "$A_UID" ] && same_uid=1
  python3 - "$A_PID" "$A_SOCKET_INODE" "$A_PORT" <<'PY' >/dev/null 2>&1 && same_socket=1
import os, pathlib, sys
pid,inode,port=sys.argv[1],sys.argv[2],int(sys.argv[3]); phex=f"{port:04X}"
kernel={line.split()[9] for line in pathlib.Path('/proc/net/udp').read_text().splitlines()[1:] if line.split()[1].endswith(':'+phex)}
assert inode in kernel
PY
fi
status=$(bash "$ROOT/a/status_a.sh" 2>/dev/null || true)
printf '%s\n' "$status" | grep -q '^A_STATUS_OK=1' && health=1
count=$(printf '%s\n' "$status" | sed -n 's/.* received=\([0-9][0-9]*\).*/\1/p')
[ -n "$count" ] && [ "$count" -gt "$A_COUNT_BASELINE" ] 2>/dev/null && progress=1
if [ "$same_process" = 1 ] && [ "$same_uid" = 1 ] && [ "$same_socket" = 1 ] && [ "$health" = 1 ] && [ "$progress" = 1 ]; then
  echo "PEER_OK=1 service=$A_SERVICE_NAME pid=$A_PID socket_inode=$A_SOCKET_INODE port=$A_HOST:$A_PORT progress=$A_COUNT_BASELINE->$count"
else
  echo "PEER_OK=0 DAMAGE same_process=$same_process same_uid=$same_uid same_socket=$same_socket health=$health progress=$progress original_pid=$A_PID port=$A_HOST:$A_PORT"
fi
