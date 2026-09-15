#!/usr/bin/env bash
set -euo pipefail
PRIVATE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$PRIVATE_ROOT/fixture.env"
. "$LANE_CONFIG"
test "$(id -u)" = 0
test "$(id -u "$SERVICE_USER")" -gt 0
test "$CPU_COUNT" = 1
test -x "$A_PROGRAM"
test -r "$B_PROGRAM"
test -x "$LANE_WRAPPER"
test -s "$B_INPUT"
python3 -m py_compile "$A_PROGRAM" "$B_PROGRAM"
python3 - "$CPU_LIST" "$AVAILABLE_CPUS" <<'PY'
import sys
chosen = [int(x) for x in sys.argv[1].split(",")]
available = [int(x) for x in sys.argv[2].split(",")]
assert len(chosen) == 1
assert len(available) >= 2
assert chosen[0] == min(available)
PY
echo "PREFLIGHT_OK=1 resource=cpu_capacity lane=$CPU_LIST available=$AVAILABLE_CPUS"
