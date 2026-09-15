#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

install -d -o agentb -g agentb -m 700 "$A_RUN_DIR"
if [ -s "$A_RUN_DIR/pid" ] && bash "$ROOT/a/status_a.sh" >/dev/null 2>&1; then
  pid=$(cat "$A_RUN_DIR/pid")
  echo "A_START already_running pid=$pid"
  exit 0
fi
rm -f "$A_RUN_DIR/pid" "$A_RUN_DIR/ready.json" "$A_RUN_DIR/stopped.json" "$A_RUN_DIR/stdout.log" "$A_RUN_DIR/stderr.log"
runuser -u agentb -- setsid python3 "$A_PROGRAM" \
  --cache-mib "$A_CACHE_MIB" \
  --run-dir "$A_RUN_DIR" \
  --fixture "$A_DATA" \
  --port "$A_PORT" \
  --guard-mib "$A_GUARD_MIB" \
  >"$A_RUN_DIR/stdout.log" 2>"$A_RUN_DIR/stderr.log" &
launcher_pid=$!
pid=""
for _ in $(seq 1 "$A_READY_ATTEMPTS"); do
  pid=$(python3 - "$A_RUN_DIR/ready.json" <<'PY'
import json, pathlib, sys
try:
    print(int(json.loads(pathlib.Path(sys.argv[1]).read_text())["pid"]))
except Exception:
    print("")
PY
)
  if [ -n "$pid" ] && [ -d "/proc/$pid" ]; then
    printf '%s\n' "$pid" > "$A_RUN_DIR/pid"
    break
  fi
  sleep "$A_READY_DELAY_SECONDS"
done
if [ -z "$pid" ]; then
  echo "A_START_FAILED launcher_pid=$launcher_pid reason=holder_pid_missing"
  echo "A_STDOUT="
  cat "$A_RUN_DIR/stdout.log" 2>/dev/null || true
  echo "A_STDERR="
  cat "$A_RUN_DIR/stderr.log" 2>/dev/null || true
  exit 1
fi
echo "A_START pid=$pid launcher_pid=$launcher_pid port=$A_PORT cache_mib=$A_CACHE_MIB"
