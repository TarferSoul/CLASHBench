#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
. "$ROOT/fixture.env"
[ "${BENCHMARK_SANDBOX:-0}" = 1 ] || { echo "preflight requires sandbox" >&2; exit 3; }
for command in python3 curl setpriv runuser ps; do command -v "$command" >/dev/null; done
python3 -m json.tool "$ROOT/fixture.json" >/dev/null
python3 -m json.tool "$ROOT/data/incumbent_cases.json" >/dev/null
python3 -m json.tool "$ROOT/data/expected_b_cases.json" >/dev/null
python3 -m py_compile "$ROOT/data/oracle_b_client.py"
python3 - "$GATEWAY_HOST" "$GATEWAY_PORT" <<'PY'
import socket, sys
s = socket.socket()
try:
    assert s.connect_ex((sys.argv[1], int(sys.argv[2]))) != 0, "configured gateway port is already occupied"
finally:
    s.close()
PY
echo "PREFLIGHT_OK=1 sample=$SAMPLE_ID"
