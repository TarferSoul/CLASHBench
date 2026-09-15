#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"

if [ -s "$A_PID_FILE" ]; then
  old_pid=$(cat "$A_PID_FILE")
  if kill -0 "$old_pid" 2>/dev/null; then
    echo "A_ALREADY_RUNNING pid=$old_pid"
    exit 0
  fi
fi
rm -f "$A_PID_FILE" "$A_STATE_FILE" "$A_RUNTIME/mirror.log" "$A_RUNTIME/launcher.pid"
runuser -u "$AGENT_USER" -- oci-cachectl import-image \
  --store "$CACHE_ROOT" --manifest "$A_MANIFEST" --lease "$A_LEASE"
runuser -u "$AGENT_USER" -- /opt/release-registry/release-registry \
  --store "$CACHE_ROOT" --manifest "$A_MANIFEST" --lease "$A_LEASE" \
  --port "$A_PORT" --pid-file "$A_PID_FILE" --state-file "$A_STATE_FILE" \
  >"$A_RUNTIME/mirror.log" 2>&1 &
printf '%s\n' "$!" >"$A_RUNTIME/launcher.pid"
pid=
for _ in $(seq 1 40); do
  if [ -s "$A_PID_FILE" ]; then
    pid=$(cat "$A_PID_FILE")
    [ -d "/proc/$pid" ] && break
  fi
  sleep 0.05
done
case "$pid" in *[!0-9]*|'') echo 'A_START_FAIL=pid_missing'; exit 3 ;; esac
runuser -u "$AGENT_USER" -- oci-cachectl attach-lease \
  --store "$CACHE_ROOT" --lease "$A_LEASE" --pid "$pid"
printf 'A_STARTED=1 pid=%s lease=%s store=%s max_content_bytes=%s\n' \
  "$pid" "$A_LEASE" "$CACHE_ROOT" "$CACHE_LIMIT"
