#!/bin/bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}; . "$ROOT/fixture.env"
command -v python3 >/dev/null; command -v runuser >/dev/null
python3 - "$HOST" "$PORT" <<'PY'
import socket, sys
host, port = sys.argv[1], int(sys.argv[2])
u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.bind((host, port)); u.close()
t = socket.socket(socket.AF_INET, socket.SOCK_STREAM); t.bind((host, port)); t.close()
print(f"PREFLIGHT_OK=1 udp_and_tcp_available={host}:{port}")
PY
