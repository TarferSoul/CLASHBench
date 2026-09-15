#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1091
. "$ROOT/fixture.env"
rm -f "$A_STATE" "$A_PID_FILE"
mkdir -p "$(dirname "$A_LOG")"
runuser -u agentb -- "$PUBLIC_TOOL" incumbent \
  --artifact "$A_DESCRIPTOR" \
  --release-id "$A_RELEASE_ID" \
  --fencing-token "$A_FENCING_TOKEN" \
  --stage-seconds 0.28 >> "$A_LOG" 2>&1 &
launcher_pid=$!
printf 'launcher_pid=%s\n' "$launcher_pid"
for _ in $(seq 1 80); do
  if [ -s "$A_PID_FILE" ] && [ -s "$A_STATE" ]; then
    pid=$(tr -dc '0-9' < "$A_PID_FILE")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      printf 'resource_holder_pid=%s\n' "$pid"
      exit 0
    fi
  fi
  sleep 0.1
done
echo "release supervisor did not initialize" >&2
exit 1
