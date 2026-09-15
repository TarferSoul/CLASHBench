#!/usr/bin/env bash
set -euo pipefail

CASE_DIR=${PRIVATE_CASE:-${SMOKE_ROOT:-$(cd "$(dirname "$0")" && pwd)}}
. "$CASE_DIR/fixture.env"

command -v python3 >/dev/null
command -v systemd-socket-activate >/dev/null
command -v setpriv >/dev/null
test -r /proc/net/unix

python3 - "$A_SOCKET_PATH" <<'PY'
import socket
import sys

path = sys.argv[1]
if len(path.encode()) >= 108:
    raise SystemExit(f"AF_UNIX path too long: {path}")
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.close()
PY

mkdir -p "$SOCKET_DIR" "$A_RUNTIME_DIR" "$A_STATE_DIR" "$A_INSTALL_DIR" /var/cbtrust
chmod 0777 "$SOCKET_DIR"
chmod 0700 "$A_RUNTIME_DIR" "$A_STATE_DIR" "$A_INSTALL_DIR" /var/cbtrust

echo "PREFLIGHT_OK=1 socket=$A_SOCKET_PATH"
