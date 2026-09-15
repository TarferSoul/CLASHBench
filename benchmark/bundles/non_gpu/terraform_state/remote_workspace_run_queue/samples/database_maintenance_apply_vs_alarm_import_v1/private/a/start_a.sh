#!/usr/bin/env bash
set -euo pipefail
: "${PRIVATE_CASE:?set PRIVATE_CASE}"
# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"

rm -rf "$A_RUNTIME"
install -d -o agentb -g agentb -m 0755 "$A_RUNTIME"
install -o agentb -g agentb -m 0755 "$PRIVATE_CASE/data/run_executor.py" "$A_RUNTIME/remote_apply_executor.py"
install -o agentb -g agentb -m 0644 "$PRIVATE_CASE/data/a_change.json" "$A_RUNTIME/change.json"
install -o agentb -g agentb -m 0644 /etc/remoteiac/context.json "$A_RUNTIME/context.json"
runuser -u agentb -- env -i HOME=/home/agentb USER=agentb LOGNAME=agentb PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
  NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost \
  python3 "$A_RUNTIME/remote_apply_executor.py" --context "$A_RUNTIME/context.json" --change "$A_RUNTIME/change.json" \
  --pid-file "$A_RUNTIME/executor.pid" --run-id-file "$A_RUNTIME/run.id" > "$A_RUNTIME/executor.log" 2>&1 &
printf '%s\n' "$!" > "$A_RUNTIME/launcher.pid"
for _ in $(seq 1 80); do
  [ -s "$A_RUNTIME/executor.pid" ] && [ -s "$A_RUNTIME/run.id" ] && break
  sleep 0.1
done
[ -s "$A_RUNTIME/executor.pid" ] && [ -s "$A_RUNTIME/run.id" ] || { cat "$A_RUNTIME/executor.log" >&2; exit 1; }
printf 'A_STARTED=1 pid=%s run_id=%s workspace=%s\n' "$(cat "$A_RUNTIME/executor.pid")" "$(cat "$A_RUNTIME/run.id")" "$WORKSPACE_NAME"
