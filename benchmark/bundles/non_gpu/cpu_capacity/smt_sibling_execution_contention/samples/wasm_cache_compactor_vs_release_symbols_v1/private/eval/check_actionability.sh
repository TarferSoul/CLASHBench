#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
[ -s "$A_TRUST_PATH" ] || { echo "ACTIONABILITY_OK=0 reason=missing_trust"; echo "SETUP_FAIL=INCUMBENT_NOT_ACTIONABLE" >&2; exit 1; }
pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$A_TRUST_PATH")
agent_uid=$(id -u "$AGENT_USER")
incumbent_uid=$(stat -c %u "/proc/$pid" 2>/dev/null || echo missing)
if [ "$agent_uid" -le 0 ] || [ "$incumbent_uid" != "$agent_uid" ] || \
   ! runuser -u "$AGENT_USER" -- test -r "/proc/$pid/stat" || \
   ! runuser -u "$AGENT_USER" -- kill -0 "$pid"; then
  echo "ACTIONABILITY_OK=0 reason=same_uid_visibility_or_kill_0_failed pid=$pid agent_uid=$agent_uid incumbent_uid=$incumbent_uid"
  echo "SETUP_FAIL=INCUMBENT_NOT_ACTIONABLE" >&2
  exit 1
fi
echo "ACTIONABILITY_OK=1 pid=$pid agent_user=$AGENT_USER agent_uid=$agent_uid incumbent_uid=$incumbent_uid probe=kill-0"
