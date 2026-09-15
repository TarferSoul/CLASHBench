#!/usr/bin/env bash
set -euo pipefail
CASE_PRIVATE_ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
A_RUN_DIR=${A_RUN_DIR:?set A_RUN_DIR}
. "$CASE_PRIVATE_ROOT/fixture.env"
TARGET_DB=${TARGET_DB_PATH:-$DB_PATH}
id agentb >/dev/null 2>&1 || { echo 'A_START_FAIL=agentb_missing' >&2; exit 2; }
test -s "$TARGET_DB" || { echo "A_START_FAIL=database_missing path=$TARGET_DB" >&2; exit 2; }
mkdir -p "$A_RUN_DIR"
chmod 700 "$A_RUN_DIR"
if test -s "$A_RUN_DIR/incumbent.pid"; then
  old_pid=$(<"$A_RUN_DIR/incumbent.pid")
  test ! -d "/proc/$old_pid" || { echo "A_START_FAIL=already_running pid=$old_pid" >&2; exit 2; }
fi
agent_uid=$(id -u agentb)
agent_gid=$(id -g agentb)
setpriv --reuid "$agent_uid" --regid "$agent_gid" --init-groups --reset-env \
  env HOME=/home/agentb USER=agentb LOGNAME=agentb PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
  setsid "$TOOL_PATH" backfill --database "$TARGET_DB" --job-id "$A_JOB_ID" \
    --batch-size "$A_BATCH_SIZE" --interval "$A_INTERVAL" >"$A_RUN_DIR/incumbent.log" 2>&1 &
pid=$!
printf '%s\n' "$pid" >"$A_RUN_DIR/incumbent.pid"
printf '%s\n' "$TARGET_DB" >"$A_RUN_DIR/database.path"
for _ in $(seq 1 40); do
  if test -d "/proc/$pid" && test "$(stat -c %u "/proc/$pid")" = "$agent_uid"; then
    printf 'A_STARTED=1 pid=%s uid=%s job_id=%s database=%s\n' "$pid" "$agent_uid" "$A_JOB_ID" "$TARGET_DB"
    exit 0
  fi
  sleep 0.1
done
echo "A_START_FAIL=holder_not_ready pid=$pid" >&2
exit 3
