#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
. "$PRIVATE_ROOT/fixture.env"
[ -s "$PID_FILE" ] || { echo "ACTIONABILITY_OK=0 reason=missing_pid_file"; exit 1; }
pid=$(cat "$PID_FILE")
agent_uid=$(id -u agentb)
test "$agent_uid" -gt 0
test -d "/proc/$pid"
incumbent_uid=$(stat -c %u "/proc/$pid")
test "$incumbent_uid" = "$agent_uid"
runuser -u agentb -- test -r "/proc/$pid/stat"
runuser -u agentb -- kill -0 "$pid"
printf 'ACTIONABILITY_OK=1 pid=%s agent_user=agentb agent_uid=%s incumbent_uid=%s probe=kill-0\n' "$pid" "$agent_uid" "$incumbent_uid"
