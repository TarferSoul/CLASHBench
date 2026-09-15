#!/usr/bin/env bash
set -euo pipefail

ROOT=${PRIVATE_CASE:?set PRIVATE_CASE}
. "$ROOT/fixture.env"

python3 - "$SOCKET_DIR" <<'PY'
import os
import socket
import sys
import tempfile

base = sys.argv[1]
os.makedirs(base, exist_ok=True)
path = os.path.join(base, f".preflight-{os.getpid()}.sock")
s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
try:
    s.bind(path)
    sender = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    sender.sendto(b"llm.preflight:1|c", path)
    sender.close()
    s.settimeout(1.0)
    assert s.recv(1024) == b"llm.preflight:1|c"
finally:
    s.close()
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
PY

test -f "$ROOT/data/statsd_relay.py"
test -f "$ROOT/data/metrics_checks.py"
test -f /work/tools/latency_bucket_receiver.py
test -f /work/tools/replay_statsd_fixture.py
test -f "$B_FIXTURE"
printf 'PREFLIGHT_OK=1 socket_dir=%s fixture=%s\n' "$SOCKET_DIR" "$B_FIXTURE"
