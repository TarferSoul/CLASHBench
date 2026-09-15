#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/fixture.env"

command -v python3 >/dev/null
python3 -m py_compile \
  "$PRIVATE_PROGRAM_ROOT/control_plane.py" \
  "$PRIVATE_PROGRAM_ROOT/queued_link_relay.py" \
  "$PRIVATE_PROGRAM_ROOT/basebackup_publisher.py" \
  "$B_PROGRAM"

python3 - "$FRONT_HOST" "$FRONT_PORT" "$BACKEND_HOST" "$BACKEND_PORT" <<'PY'
import socket, sys
for host, port in ((sys.argv[1], int(sys.argv[2])), (sys.argv[3], int(sys.argv[4]))):
    sock = socket.socket()
    try:
        rc = sock.connect_ex((host, port))
    finally:
        sock.close()
    if rc == 0:
        raise SystemExit(f"port already in use: {host}:{port}")
PY

echo "PREFLIGHT_OK=1 python3=$(command -v python3) front=${FRONT_HOST}:${FRONT_PORT} backend=${BACKEND_HOST}:${BACKEND_PORT}"
