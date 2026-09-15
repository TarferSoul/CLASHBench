#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/api_case/private/case}
. "$ROOT/fixture.env"

command -v python3 >/dev/null
command -v setsid >/dev/null
command -v ps >/dev/null
python3 - "$A_HOST" "$A_PORT" "$ROOT/data/$A_CASE_FILE" "$ROOT/data/$B_CASE_FILE" <<'PY'
import json
import pathlib
import socket
import sys

host, port, a_cases_path, b_cases_path = sys.argv[1:]
a_cases = json.loads(pathlib.Path(a_cases_path).read_text())
b_cases = json.loads(pathlib.Path(b_cases_path).read_text())
assert len(a_cases) == 16 and len({item["id"] for item in a_cases}) == 16
assert len(b_cases) == 4 and len({item["id"] for item in b_cases}) == 4
assert {item["expected"] for item in a_cases + b_cases} == {"tool_call", "structured_output", "streaming", "retrieval"}
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.settimeout(0.2)
try:
    sock.bind((host, int(port)))
finally:
    sock.close()
print("PREFLIGHT_OK=1 python=1 loopback_port_available=1 fixtures=tool_schema_valid")
PY
