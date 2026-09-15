#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

ensure_account() {
  local user=$1 uid=$2 gid=$3
  if getent group "$user" >/dev/null 2>&1; then
    [ "$(getent group "$user" | cut -d: -f3)" = "$gid" ]
  else
    groupadd -g "$gid" "$user"
  fi
  if getent passwd "$user" >/dev/null 2>&1; then
    [ "$(id -u "$user")" = "$uid" ] && [ "$(id -g "$user")" = "$gid" ]
  else
    useradd -u "$uid" -g "$gid" -M -s /usr/sbin/nologin "$user"
  fi
}

ensure_account "$SERVICE_USER" "$SERVICE_UID" "$SERVICE_GID"
ensure_account "$B_USER" "$B_UID" "$B_GID"
command -v python3 >/dev/null
command -v ss >/dev/null
[ "$(uname -s)" = Linux ]

python3 - "$SERVICE_UID" "$SERVICE_GID" "$B_UID" "$B_GID" "$A_HOST" "$PREFLIGHT_PORT" <<'PY'
import errno
import os
import socket
import sys
import time

service_uid, service_gid, task_uid, task_gid = map(int, sys.argv[1:5])
host, port = sys.argv[5], int(sys.argv[6])
assert socket.AF_INET == 2 and hasattr(socket, "SO_REUSEPORT")
ready_r, ready_w = os.pipe()
service_pid = os.fork()
if service_pid == 0:
    try:
        os.close(ready_r)
        os.setgroups([]); os.setgid(service_gid); os.setuid(service_uid)
        sockets = []
        for _ in range(2):
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
            sock.bind((host, port)); sock.listen(2); sockets.append(sock)
        os.write(ready_w, b"ready")
        while True: time.sleep(0.2)
    except BaseException:
        os._exit(20)
os.close(ready_w)
if os.read(ready_r, 5) != b"ready":
    os.kill(service_pid, 9); os.waitpid(service_pid, 0)
    raise SystemExit("service group preflight failed")
task_pid = os.fork()
if task_pid == 0:
    try:
        os.setgroups([]); os.setgid(task_gid); os.setuid(task_uid)
        errors = []
        for reuse in (False, True):
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            if reuse: sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEPORT, 1)
            try: sock.bind((host, port)); errors.append(None)
            except OSError as exc: errors.append(exc.errno)
            sock.close()
        os._exit(0 if errors == [errno.EADDRINUSE, errno.EADDRINUSE] else 21)
    except BaseException:
        os._exit(22)
_, status = os.waitpid(task_pid, 0)
os.kill(service_pid, 15); os.waitpid(service_pid, 0)
if not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
    raise SystemExit("credential-scoped admission contract failed")
print(f"PREFLIGHT_REUSEPORT_OK=1 kernel={os.uname().release} family=AF_INET transport=TCP service_uid={service_uid} task_uid={task_uid} ordinary_errno=EADDRINUSE reuseport_errno=EADDRINUSE")
PY
printf 'PREFLIGHT_OK=1 endpoint=%s:%s workers=%s\n' "$A_HOST" "$A_PORT" "$A_WORKERS"
