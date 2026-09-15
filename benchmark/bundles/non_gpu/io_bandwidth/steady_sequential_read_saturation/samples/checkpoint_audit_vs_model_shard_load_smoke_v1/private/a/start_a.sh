#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:?}}"
set -a
# shellcheck disable=SC1090
. "$ROOT/fixture.env"
set +a

id agentb >/dev/null 2>&1 || useradd -m -s /bin/bash agentb
agent_uid=$(id -u agentb)
agent_gid=$(id -g agentb)
mkdir -p "$A_STATE_ROOT"
chown agentb:agentb "$A_STATE_ROOT"
chmod 700 "$A_STATE_ROOT"
if [ -s "$A_PID_FILE" ]; then
  old_pid="$(cat "$A_PID_FILE" 2>/dev/null || true)"
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    echo "A_ALREADY_RUNNING pid=$old_pid"
    exit 0
  fi
fi

cp "$ROOT/data/audit_checkpoint.py" /usr/local/bin/model-artifact-auditor
cp "$ROOT/data/artifact_io.py" /usr/local/bin/artifact_io.py
chmod 755 /usr/local/bin/model-artifact-auditor /usr/local/bin/artifact_io.py
rm -f "$A_STATUS_FILE" "$A_HEARTBEAT_FILE" "$A_LOG"
setpriv --reuid="$agent_uid" --regid="$agent_gid" --init-groups -- setsid env -i \
  PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  PYTHONUNBUFFERED=1 \
  PYTHONPATH="/usr/local/bin" \
  CHECKPOINT_ID="$CHECKPOINT_ID" \
  A_VISIBLE_ROOT="$A_VISIBLE_ROOT" \
  A_STATE_ROOT="$A_STATE_ROOT" \
  A_SHARD_COUNT="$A_SHARD_COUNT" \
  A_DIRECT_STREAMS="$A_DIRECT_STREAMS" \
  DIRECT_BLOCK_BYTES="$DIRECT_BLOCK_BYTES" \
  HASH_SAMPLE_BYTES="$HASH_SAMPLE_BYTES" \
  python3 /usr/local/bin/model-artifact-auditor >>"$A_LOG" 2>&1 &
pid=$!
printf '%s\n' "$pid" >"$A_PID_FILE"
echo "A_STARTED pid=$pid state=$A_STATE_ROOT"
