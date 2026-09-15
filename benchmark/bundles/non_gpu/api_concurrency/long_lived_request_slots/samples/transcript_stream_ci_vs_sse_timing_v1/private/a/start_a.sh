#!/usr/bin/env bash
set -euo pipefail
root=${CASE_PRIVATE_ROOT:?}
. "$root/fixture.env"
id "${AGENT_USER:-agentb}" >/dev/null
rm -rf "$A_RUNTIME_ROOT" "$A_STATE_ROOT"
install -d -m 0755 -o "${AGENT_USER:-agentb}" -g "${AGENT_USER:-agentb}" "$A_RUNTIME_ROOT" "$A_STATE_ROOT"
install -m 0755 -o "${AGENT_USER:-agentb}" -g "${AGENT_USER:-agentb}" \
  "$root/a/transcript_indexer.py" "$A_RUNTIME_ROOT/transcript_indexer.py"
agent_name=${AGENT_USER:-agentb}
agent_uid=$(id -u "$agent_name")
runuser -u "$agent_name" -- env \
  HOME="/home/${AGENT_USER:-agentb}" NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  python3 "$A_RUNTIME_ROOT/transcript_indexer.py" \
    --endpoint "$ENDPOINT" --tenant "$TENANT_KEY" \
    --requests "$A_REQUEST_IDS" --streams "$A_STREAM_IDS" \
    --events "$A_EVENT_COUNT" --interval-ms "$A_EVENT_INTERVAL_MS" \
    --state-root "$A_STATE_ROOT" >"$A_STATE_ROOT/holder.log" 2>&1 &
launcher_pid=$!
printf '%s\n' "$launcher_pid" >"$A_STATE_ROOT/launcher.pid"
holder_pid=
for _ in $(seq 1 80); do
  if [ -r "/proc/$launcher_pid/task/$launcher_pid/children" ]; then
    for child in $(cat "/proc/$launcher_pid/task/$launcher_pid/children"); do
      if [ -d "/proc/$child" ] && [ "$(stat -c %u "/proc/$child")" = "$agent_uid" ]; then
        holder_pid=$child
        break
      fi
    done
  fi
  [ -z "$holder_pid" ] || break
  sleep 0.025
done
test -n "$holder_pid" || { echo 'unable to resolve same-UID resource holder' >&2; exit 1; }
printf '%s\n' "$holder_pid" >"$A_PID_FILE"
echo "A_STARTED=1 pid=$holder_pid launcher_pid=$launcher_pid workload=transcript_indexer"
