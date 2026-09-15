#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 40); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
  done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
fi
runuser -u "$AGENT_USER" -- model-cachectl release \
  --cache "$CACHE_ROOT" --lease "$A_LEASE" --evict --force
rm -f "$A_PID_FILE" "$A_STATE_FILE"
printf 'A_STOPPED=1 pid=%s released_lease=%s\n' "${pid:-none}" "$A_LEASE"
