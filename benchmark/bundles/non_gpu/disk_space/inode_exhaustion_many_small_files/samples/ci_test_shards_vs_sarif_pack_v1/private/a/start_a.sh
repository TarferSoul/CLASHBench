#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
rm -rf "$A_OUTPUT_ROOT"
rm -f "$A_PID_FILE" "$A_LOG_FILE"
mkdir -p "$(dirname "$A_PID_FILE")"
setpriv --reuid="$AGENT_UID" --regid="$AGENT_GID" --keep-groups \
  setsid "/usr/local/libexec/$A_TOOL_NAME" \
  --root "$A_OUTPUT_ROOT" --results "$A_RESULT_FILES" --coverage "$A_COVERAGE_FILES" --logs "$A_LOG_FILES" \
  >"$A_LOG_FILE" 2>&1 < /dev/null &
pid=$!
printf '%s\n' "$pid" >"$A_PID_FILE"
for _ in $(seq 1 40); do
  [ -d "/proc/$pid" ] && break
  sleep 0.05
done
printf 'A_STARTED=1 PID=%s UID=%s\n' "$pid" "$(stat -c %u "/proc/$pid")"
