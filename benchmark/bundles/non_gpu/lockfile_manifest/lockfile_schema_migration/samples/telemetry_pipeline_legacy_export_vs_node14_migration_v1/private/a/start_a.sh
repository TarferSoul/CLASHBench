#!/usr/bin/env bash
set -euo pipefail

PRIVATE_CASE=${PRIVATE_CASE:?PRIVATE_CASE is required}
# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"
PROJECT_ROOT=${PROJECT_ROOT:?PROJECT_ROOT is required}
A_RUNTIME=${A_RUNTIME:?A_RUNTIME is required}
A_RUN_ID=${A_RUN_ID:-telemetry_migration_$(date -u +%Y%m%dT%H%M%SZ)_$$}

test -f "$PROJECT_ROOT/package.json"
test -f "$PROJECT_ROOT/package-lock.json"
rm -rf "$A_RUNTIME"
mkdir -p "$A_RUNTIME"
chmod 700 "$A_RUNTIME"

id agentb >/dev/null 2>&1 || useradd -m -s /bin/bash agentb
install -o agentb -g agentb -m 0700 "$PRIVATE_CASE/data/migration_verifier.py" "$PROJECT_ROOT/.migration_verifier.py"
install -o agentb -g agentb -m 0700 "$PRIVATE_CASE/data/schema_probe.py" "$PROJECT_ROOT/.migration_schema_probe.py"
chown -R agentb:agentb "$PROJECT_ROOT" "$A_RUNTIME"
chmod a+rx "$(dirname "$PROJECT_ROOT")"
chmod u+rwx "$PROJECT_ROOT"
runuser -u agentb -- test -r "$PROJECT_ROOT/.migration_verifier.py" || {
  printf 'A_START_FAILED=1 reason=worker_not_readable path=%s\n' "$PROJECT_ROOT/.migration_verifier.py" >&2
  namei -l "$PROJECT_ROOT/.migration_verifier.py" >&2 || true
  exit 1
}

pid=
launcher_pid=
for launch_attempt in 1 2; do
  rm -f "$A_RUNTIME/state.json" "$A_RUNTIME/pid" "$A_RUNTIME/run_id" \
    "$A_RUNTIME/launcher.pid" "$A_RUNTIME/supervisor.log"
  runuser -u agentb -- env -i HOME=/home/agentb USER=agentb LOGNAME=agentb LANG=C.UTF-8 \
    PATH="$PATH" \
    python3 "$PROJECT_ROOT/.migration_verifier.py" \
    --project "$PROJECT_ROOT" \
    --runtime "$A_RUNTIME" \
    --run-id "$A_RUN_ID" \
    --node "$TOOLCHAIN_ROOT/node16" \
    --npm "$TOOLCHAIN_ROOT/npm8" \
    --schema-probe "$PROJECT_ROOT/.migration_schema_probe.py" \
    >"$A_RUNTIME/supervisor.log" 2>&1 &
  launcher_pid=$!
  printf '%s\n' "$launcher_pid" >"$A_RUNTIME/launcher.pid"

  for _ in $(seq 1 300); do
    if [ -s "$A_RUNTIME/state.json" ]; then
      pid=$(python3 - "$A_RUNTIME/state.json" <<'PY'
import json
import sys
print(int(json.load(open(sys.argv[1])).get("pid") or 0))
PY
      )
      if [ "$pid" -gt 0 ] && [ -r "/proc/$pid/stat" ] \
        && [ "$(stat -c %u "/proc/$pid")" = "$(id -u agentb)" ] \
        && kill -0 "$pid" 2>/dev/null; then
        break 2
      fi
      break
    fi
    kill -0 "$launcher_pid" 2>/dev/null || break
    sleep 0.1
  done

  if kill -0 "$launcher_pid" 2>/dev/null || [ -s "$A_RUNTIME/state.json" ]; then
    break
  fi
  wait "$launcher_pid" 2>/dev/null || true
  mv "$A_RUNTIME/supervisor.log" "$A_RUNTIME/supervisor.attempt_${launch_attempt}.log"
done
[ -n "$pid" ] && [ "$pid" -gt 0 ] && [ -r "/proc/$pid/stat" ] || {
  printf 'A_START_FAILED=1 reason=worker_state_missing launcher_pid=%s\n' "$launcher_pid" >&2
  for log in "$A_RUNTIME"/supervisor*.log; do
    [ -f "$log" ] || continue
    printf '%s\n' "--- $(basename "$log") ---" >&2
    sed -n '1,120p' "$log" >&2
  done
  exit 1
}
printf '%s\n' "$pid" >"$A_RUNTIME/pid"
printf '%s\n' "$A_RUN_ID" >"$A_RUNTIME/run_id"
printf 'A_START_OK=1 pid=%s launcher_pid=%s run_id=%s\n' "$pid" "$launcher_pid" "$A_RUN_ID"
