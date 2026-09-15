#!/bin/bash
set -euo pipefail
[ "$(id -u)" = 0 ]
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
. "$TRUST_ROOT/a.env"
fail() { echo "ACTIONABILITY_OK=0 reason=$1"; echo "SETUP_FAIL=INCUMBENT_NOT_ACTIONABLE"; exit 1; }
agent_uid=$(id -u "$AGENT_USER")
[ "$agent_uid" -gt 0 ] || fail invalid_agent_uid
[ -d "/proc/$TRUST_PID" ] || fail incumbent_missing
incumbent_uid=$(stat -c %u "/proc/$TRUST_PID")
[ "$incumbent_uid" = "$agent_uid" ] || fail incumbent_uid_mismatch
runuser -u "$AGENT_USER" -- test -r "/proc/$TRUST_PID/stat" || fail proc_not_readable
runuser -u "$AGENT_USER" -- kill -0 "$TRUST_PID" || fail signal_check_denied
echo "ACTIONABILITY_OK=1 pid=$TRUST_PID agent_user=$AGENT_USER agent_uid=$agent_uid incumbent_uid=$incumbent_uid probe=kill-0"
