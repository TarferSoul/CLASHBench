#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
agent_uid=${AGENT_UID:?}
agent_gid=${AGENT_GID:?}

if [ -r "$A_PID_FILE" ]; then
  old_pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    echo "A_ALREADY_RUNNING pid=$old_pid" >&2
    exit 1
  fi
fi
rm -f "$A_PROGRESS" "$A_COMMIT_META" "$A_LOG_FILE" "$A_PID_FILE" "$A_LAUNCHER_PID_FILE"
setsid setpriv --reuid "$agent_uid" --regid "$agent_gid" --init-groups --reset-env \
  env HOME=/home/agentb USER=agentb LOGNAME=agentb PATH=/usr/local/bin:/usr/bin:/bin \
  python3 "$LEDGER_BIN" \
    --log "$LEDGER_LOG" \
    --lock "$LEDGER_LOCK" \
    --input "$A_BATCH" \
    --transaction "$A_TRANSACTION" \
    --commit-metadata "$A_COMMIT_META" \
    --timeout 2 \
    --record-delay "$A_RECORD_DELAY" \
    --progress "$A_PROGRESS" \
    --actor registry-provenance-importer \
    > "$A_LOG_FILE" 2>&1 < /dev/null &
pid=$!
printf '%s\n' "$pid" > "$A_PID_FILE"
for _ in $(seq 1 160); do
  if kill -0 "$pid" 2>/dev/null && bash "$ROOT/a/status_a.sh" >/dev/null 2>&1; then
    echo "A_STARTED pid=$pid agent_uid=$agent_uid transaction=$A_TRANSACTION batch=$A_BATCH"
    exit 0
  fi
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.1
done
cat "$A_LOG_FILE" >&2 2>/dev/null || true
echo "A_START_FAILED pid=$pid agent_uid=$agent_uid" >&2
ps -o pid,ppid,pgid,euid,stat,cmd -p "$pid" >&2 || true
ls -l "$A_PROGRESS" "$A_LOG_FILE" "$A_BATCH" >&2 || true
stat -Lc 'path=%n dev=%d inode=%i' "$LEDGER_LOCK" "$LEDGER_LOG" >&2 || true
for fd in /proc/$pid/fd/*; do readlink "$fd"; done >&2 || true
bash "$ROOT/a/status_a.sh" >&2 || true
cat "$A_PROGRESS" >&2 2>/dev/null || true
exit 1
