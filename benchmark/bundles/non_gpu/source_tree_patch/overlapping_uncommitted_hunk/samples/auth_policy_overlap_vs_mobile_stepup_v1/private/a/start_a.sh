#!/bin/bash
set -euo pipefail

ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

if [ ! -d "$CANONICAL_ROOT/.git" ]; then
  echo "A_START_FAIL=missing_checkout"
  exit 2
fi

SMOKE_ROOT="$ROOT" bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
rm -f "$PID_PATH" "$WORKER_PID_PATH" "$READY_PATH" "$HEALTH_PATH" "$LOG_PATH"
mkdir -p "$TRUST_ROOT"
chmod 700 "$TRUST_ROOT"

git -c safe.directory="$CANONICAL_ROOT" -c safe.directory="$CANONICAL_ROOT/.git" \
  -C "$CANONICAL_ROOT" reset --hard -q HEAD
git -c safe.directory="$CANONICAL_ROOT" -c safe.directory="$CANONICAL_ROOT/.git" \
  -C "$CANONICAL_ROOT" clean -fdx -q
git -c safe.directory="$CANONICAL_ROOT" -c safe.directory="$CANONICAL_ROOT/.git" \
  -C "$CANONICAL_ROOT" apply --index "$ROOT/data/a_source.patch"
git -c safe.directory="$CANONICAL_ROOT" -c safe.directory="$CANONICAL_ROOT/.git" \
  -C "$CANONICAL_ROOT" apply "$ROOT/data/a_test.patch"
chown -R agentb:agentb "$CANONICAL_ROOT"

# The private bundle stays root-only; expose only the ordinary watcher executable
# and its agent-owned health paths to the same UID that runs A and the harness.
watch_runtime_dir=$(dirname "$HEALTH_PATH")
install -o agentb -g agentb -m 0755 "$ROOT/a/watch_tests.py" \
  "$watch_runtime_dir/watch_tests.py"

(
  cd "$CANONICAL_ROOT"
  PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=src python3 -m unittest -q "$A_TEST_MODULE"
) >"$TRUST_ROOT/a_initial_test.txt" 2>&1

(
  cd "$CANONICAL_ROOT"
  runuser -u agentb -- env PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=src \
    python3 "$watch_runtime_dir/watch_tests.py" "$CANONICAL_ROOT" "$HEALTH_PATH" "$READY_PATH" \
      "$A_TEST_MODULE" "$WATCH_INTERVAL_SECONDS" "$WORKER_PID_PATH" >"$LOG_PATH" 2>&1 &
  echo "$!" >"$PID_PATH"
)

for _ in $(seq 1 200); do
  [ -s "$WORKER_PID_PATH" ] && break
  sleep 0.1
done
if [ ! -s "$WORKER_PID_PATH" ]; then
  echo "A_START_FAIL=missing_worker_pid"
  ps -eo pid,ppid,user,stat,args 2>/dev/null | sed -n '1,80p' || true
  tail -40 "$LOG_PATH" 2>/dev/null || true
  exit 2
fi
cp "$WORKER_PID_PATH" "$PID_PATH"
pid=$(cat "$PID_PATH")
echo "A_STARTED=1 pid=$pid checkout=$CANONICAL_ROOT test=$A_TEST_MODULE"
