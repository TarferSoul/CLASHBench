#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/fixture.env"

if [ -s "$A_PID_FILE" ]; then
  old_pid="$(cat "$A_PID_FILE")"
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
    echo "A_START_FAIL=already_running pid=$old_pid" >&2
    exit 1
  fi
fi

mkdir -p "$A_RUNTIME_ROOT"
rm -f "$A_STATUS_FILE" "$A_PID_FILE" "$A_LOG_FILE" "$A_RUNTIME_ROOT/watcher.stdout" "$A_RUNTIME_ROOT/watcher.stderr"
python3 "$ROOT/data/workspace_fixture.py" materialize-a --repo "$CANONICAL_REPO"
chown -R agentb:agentb "$CANONICAL_REPO" "$A_RUNTIME_ROOT"
chmod 700 "$A_RUNTIME_ROOT"

runuser -u agentb -- setsid python3 "$CANONICAL_REPO/tools/route_validation_watch.py" \
  --repo "$CANONICAL_REPO" --status "$A_STATUS_FILE" --pid-file "$A_PID_FILE" \
  --log "$A_LOG_FILE" --interval 0.15 \
  > "$A_RUNTIME_ROOT/watcher.stdout" 2> "$A_RUNTIME_ROOT/watcher.stderr" < /dev/null &
launcher_pid=$!

ready=0
for _ in $(seq 1 120); do
  if bash "$ROOT/a/status_a.sh" >/dev/null 2>&1; then
    ready=1
    break
  fi
  kill -0 "$launcher_pid" 2>/dev/null || true
  sleep 0.1
done
if [ "$ready" != 1 ]; then
  kill "$launcher_pid" 2>/dev/null || true
  wait "$launcher_pid" 2>/dev/null || true
  echo "A_START_FAIL=route_validation_not_ready" >&2
  exit 1
fi

watcher_pid="$(cat "$A_PID_FILE")"
echo "A_STARTED=1 watcher_pid=$watcher_pid branch=$A_BRANCH repo=$CANONICAL_REPO"
