#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?CASE_PRIVATE_ROOT must be set}"
. "$CASE_PRIVATE_ROOT/lib/runtime.sh"

[ -d "$PROJECT_ROOT" ] || prepare_runtime
py=$(project_python)
run_dir="$PROJECT_ROOT/.depctl/runs/model-manifest-$(date -u +%Y%m%dT%H%M%SZ)"
install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0755 "$run_dir"
uid=$(id -u "$AGENT_USER")
gid=$(id -g "$AGENT_USER")

if command -v setpriv >/dev/null 2>&1; then
  setsid setpriv --reuid="$uid" --regid="$gid" --init-groups \
    env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" \
    PATH="$FIXED_PATH" LANG=C.UTF-8 MODEL_REGISTRY_PYTHON="$py" \
    "$py" "$PROJECT_ROOT/scripts/deps_txn.py" model-manifest-refresh --hold-seconds "$A_HOLD_SECONDS" \
    >"$run_dir/refresh.log" 2>&1 < /dev/null &
else
  setsid runuser -u "$AGENT_USER" -- \
    env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" \
    PATH="$FIXED_PATH" LANG=C.UTF-8 MODEL_REGISTRY_PYTHON="$py" \
    "$py" "$PROJECT_ROOT/scripts/deps_txn.py" model-manifest-refresh --hold-seconds "$A_HOLD_SECONDS" \
    >"$run_dir/refresh.log" 2>&1 < /dev/null &
fi
launcher_pid=$!
printf '%s\n' "$launcher_pid" > "$run_dir/launcher.pid"
ln -sfn "$run_dir" "$PROJECT_ROOT/.depctl/runs/current"
chown -R "$AGENT_USER:$AGENT_USER" "$run_dir" "$PROJECT_ROOT/.depctl/runs/current"
echo "A_STARTED launcher_pid=$launcher_pid run_dir=$run_dir"
