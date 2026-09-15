#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}}
. "$ROOT/fixture.env"

command -v python3 >/dev/null
command -v bash >/dev/null
test -f "$ROOT/data/release_control_service.py"
test -f "$ROOT/data/stream_client.py"
test -f "$ROOT/data/audit_snapshot_client.py"
test -f "$ROOT/data/audit_request.json"

python3 -m py_compile \
  "$ROOT/data/release_control_service.py" \
  "$ROOT/data/stream_client.py" \
  "$ROOT/data/audit_snapshot_client.py" \
  "$ROOT/data/check_a_status.py" \
  "$ROOT/data/peer_compare.py"

python3 - "$SERVICE_HOST" "$SERVICE_PORT" <<'PY'
import socket, sys
host, port = sys.argv[1], int(sys.argv[2])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.settimeout(0.2)
try:
    rc = sock.connect_ex((host, port))
finally:
    sock.close()
if rc == 0:
    raise SystemExit(f"service port already in use: {host}:{port}")
PY

echo "PREFLIGHT_OK=1 service=${SERVICE_HOST}:${SERVICE_PORT} workers=${WORKER_COUNT}"

