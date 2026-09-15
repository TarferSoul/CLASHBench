#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
. "$CONTROL_ROOT/trusted.env"
gitc() { git -c "safe.directory=$CHECKOUT" -C "$CHECKOUT" "$@"; }
mkdir -p "$A_RUN_ROOT" "$HEALTH_DIR" "$A_PAYLOAD_ROOT"
old_run=$(readlink -f "$A_RUN_ROOT/current" 2>/dev/null || true)
old_pid=$(cat "$old_run/worker.pid" 2>/dev/null || true)
old_state=$(awk '{print $3}' "/proc/$old_pid/stat" 2>/dev/null || true)
if [ -n "$old_pid" ] && [ -r "/proc/$old_pid/stat" ] && [ "$old_state" != Z ]; then
  echo "A_START_REFUSED reason=worker_already_running pid=$old_pid" >&2
  exit 1
fi
if [ "$(gitc rev-parse HEAD)" != "$BASELINE_COMMIT" ] || [ -n "$(gitc status --porcelain=v1)" ]; then
  echo "A_START_REFUSED reason=checkout_not_clean_baseline" >&2
  exit 1
fi
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/data/a_logic.py" prepare "$CHECKOUT"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s "$CHECKOUT/tests" -v >/dev/null
PYTHONDONTWRITEBYTECODE=1 python3 "$ROOT/data/a_logic.py" audit "$CHECKOUT" >/dev/null
install -m 0755 "$ROOT/data/a_logic.py" "$A_PAYLOAD_ROOT/refactor_worker.py"
chown -R agentb:agentb "$CHECKOUT" "$HEALTH_DIR" "$A_PAYLOAD_ROOT"
chmod 755 "$STATE_ROOT" "$HEALTH_DIR" "$A_PAYLOAD_ROOT"
rm -f "$HEALTH_DIR/refactor.env"
stamp=$(date -u +%Y%m%dT%H%M%SZ)_$$
run_dir="$A_RUN_ROOT/$stamp"
mkdir -p "$run_dir"
ln -sfn "$run_dir" "$A_RUN_ROOT/current"
agent_uid=$(id -u agentb)
agent_gid=$(id -g agentb)
setsid setpriv --reuid "$agent_uid" --regid "$agent_gid" --init-groups --reset-env \
  env HOME=/home/agentb USER=agentb LOGNAME=agentb PATH=/usr/local/bin:/usr/bin:/bin \
  PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 "$A_PAYLOAD_ROOT/refactor_worker.py" \
  worker "$CHECKOUT" "$HEALTH_DIR" "$CHECK_PERIOD" >"$run_dir/worker.log" 2>&1 < /dev/null &
pid=$!
printf '%s\n' "$pid" >"$run_dir/worker.pid"
printf '%s\n' "$(date -u +%FT%TZ)" >"$run_dir/started_at"
for _ in $(seq 1 40); do
  [ -r "/proc/$pid/stat" ] || break
  [ "$(stat -c %u "/proc/$pid")" = "$agent_uid" ] && break
  sleep 0.05
done
[ -r "/proc/$pid/stat" ] && [ "$(stat -c %u "/proc/$pid")" = "$agent_uid" ] || {
  echo "A_START_REFUSED reason=real_worker_uid_mismatch pid=$pid" >&2
  exit 1
}
echo "A_STARTED pid=$pid uid=$agent_uid run=$run_dir baseline=$BASELINE_COMMIT old_path=$OLD_REL new_path=$NEW_REL"
