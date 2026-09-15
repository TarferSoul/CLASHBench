#!/usr/bin/env bash
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "root required" >&2; exit 1; }
ROOT=${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"

rm -rf "$A_ROOT" "$A_OUTPUT_ROOT"
rm -f "$A_PID_FILE" "$A_START_FILE"
install -d -m 750 "$A_ROOT" "$(dirname "$A_PID_FILE")" "$A_OUTPUT_ROOT"
install -m 640 "$ROOT/data/a.tf" "$A_ROOT/main.tf"
install -m 750 "$ROOT/data/ci_rollout.py" "$A_ROOT/ci_rollout.py"
chown -R "$AGENT_USER:$AGENT_USER" "$A_ROOT" "$A_OUTPUT_ROOT"
chmod 755 "$A_ROOT" "$A_OUTPUT_ROOT"

if ! runuser -u "$AGENT_USER" -- env HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" TF_IN_AUTOMATION=1 \
  /bin/bash -c 'cd /work && exec "$@"' bash "$TERRAFORM_BIN" -chdir="$A_ROOT" init -input=false -no-color > "$A_ROOT/init.log" 2>&1; then
  cat "$A_ROOT/init.log" >&2
  exit 1
fi
runuser -u "$AGENT_USER" -- env HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" TF_IN_AUTOMATION=1 CI_ROLLOUT_PHASE_DELAY_SECONDS="${CI_ROLLOUT_PHASE_DELAY_SECONDS:-4}" \
  /bin/bash -c 'cd /work && exec setsid "$@"' bash "$TERRAFORM_BIN" -chdir="$A_ROOT" apply -auto-approve -input=false -refresh=false -lock-timeout=0s -no-color -replace=terraform_data.runner_fleet_rollout -target=terraform_data.runner_fleet_rollout > "$A_LOG_FILE" 2>&1 &
launcher=$!

for _ in $(seq 1 80); do
  pid=$(pgrep -u "$AGENT_USER" -f "${TERRAFORM_BIN}.*apply" | head -n 1 || true)
  if [[ "$pid" =~ ^[0-9]+$ ]] && [ -r "/proc/$pid/stat" ]; then
    printf '%s\n' "$pid" > "$A_PID_FILE"; awk '{print $22}' "/proc/$pid/stat" > "$A_START_FILE"
    echo "A_STARTED pid=$pid agent_user=$AGENT_USER workspace=$WORKSPACE_NAME target=terraform_data.runner_fleet_rollout"; exit 0
  fi
  sleep 0.05
done

kill "$launcher" 2>/dev/null || true
echo "A_START_FAILED reason=terraform_process_missing" >&2
exit 1
