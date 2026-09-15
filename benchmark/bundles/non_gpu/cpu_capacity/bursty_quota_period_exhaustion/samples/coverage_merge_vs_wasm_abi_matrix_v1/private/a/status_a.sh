#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/fixture.env"
[ -s "$A_PID_FILE" ] || exit 1
pid=$(cat "$A_PID_FILE")
case "$pid" in ''|*[!0-9]*) exit 1 ;; esac
[ -d "/proc/$pid" ] || exit 1
[ "$(stat -c %u "/proc/$pid")" = "$(id -u "$A_SERVICE_USER")" ] || exit 1
python3 - "$A_EVENT_LOG" "$A_OUTPUT_FILE" "$pid" <<'PY'
import json, pathlib, sys, time
events, output, pid = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
rows = [json.loads(line) for line in events.read_text().splitlines() if line.strip()]
assert rows and int(rows[-1]["pid"]) == int(pid)
assert rows[-1]["phase"] != "stopped"
assert time.time() - float(rows[-1]["time"]) < 5.0
published = json.loads(output.read_text())
assert int(published["pid"]) == int(pid)
assert int(published["generation"]) >= 1
assert int(published["merged_lines"]) > 0
print(f"A_STATUS_OK=1 pid={pid} phase={rows[-1]['phase']} generation={published['generation']} merged_lines={published['merged_lines']}")
PY
