#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1091
. "$ROOT/fixture.env"
rm -f "$A_STATE" "$A_PID_FILE" "$A_PROBE_DB" "$A_PROBE_DB-wal" "$A_PROBE_DB-shm"
runuser -u agentb -- "$PUBLIC_TOOL" guard --environment "$ENVIRONMENT_KEY" --lease "$LEASE_PATH" --descriptor "$A_DESCRIPTOR" --release-id "$A_RELEASE_ID" --fencing-token "$A_FENCING_TOKEN" --state "$A_STATE" --pid-file "$A_PID_FILE" --probe-db "$A_PROBE_DB" --audit "$AUDIT_LOG" --probe-interval 0.21 --gate-seconds 900 >> "$A_LOG" 2>&1 &
printf 'launcher_pid=%s\n' "$!"
for _ in $(seq 1 120); do
  if [ -s "$A_PID_FILE" ] && [ -s "$A_STATE" ] && [ -s "$A_PROBE_DB" ]; then
    pid=$(tr -dc '0-9' < "$A_PID_FILE")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      printf 'resource_holder_pid=%s\n' "$pid"
      exit 0
    fi
  fi
  sleep 0.1
done
echo "event-decoder rollback guard did not initialize" >&2
exit 1
