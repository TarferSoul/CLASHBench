#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}}
. "$ROOT/fixture.env"

rm -rf "$A_CORPUS_ROOT" "$A_STATE_DIR"
install -d -m 755 "$DATA_ROOT"
install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 755 "$A_CORPUS_ROOT"
install -d -o root -g root -m 711 "$(dirname "$A_STATE_DIR")"
install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 700 "$A_STATE_DIR"
rm -f "$A_PID_FILE" "$A_PGID_FILE" "$A_START_FILE" "$A_STATUS_FILE" "$A_WORKER_TABLE" "$A_LOG_FILE"
install -o "$AGENT_USER" -g "$AGENT_USER" -m 500 "$ROOT/data/corpus_materializer.py" "$A_STATE_DIR/corpus_materializer_runtime.py"
install -o "$AGENT_USER" -g "$AGENT_USER" -m 600 /dev/null "$A_LOG_FILE"

setsid runuser -u "$AGENT_USER" -- env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" \
  PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" PYTHONUNBUFFERED=1 \
  python3 "$A_STATE_DIR/corpus_materializer_runtime.py" supervise \
    --root "$A_CORPUS_ROOT" \
    --state-dir "$A_STATE_DIR" \
    --status-file "$A_STATUS_FILE" \
    --manifest-file "$A_MANIFEST_FILE" \
    --pid-file "$A_PID_FILE" \
    --worker-table "$A_WORKER_TABLE" \
    --workers "$A_WORKERS" \
    --group-mib "$A_GROUP_MIB" \
    --block-mib "$A_BLOCK_MIB" \
    --retained-groups "$A_RETAINED_GROUPS" \
  >>"$A_LOG_FILE" 2>&1 < /dev/null &

for _ in $(seq 1 120); do
  [ -s "$A_PID_FILE" ] && break
  sleep 0.05
done

[ -s "$A_PID_FILE" ] || { echo "A_START_FAIL=no_supervisor_pid"; sed -n '1,120p' "$A_LOG_FILE" >&2 2>/dev/null || true; exit 1; }
pid=$(cat "$A_PID_FILE")
kill -0 "$pid"
awk '{print $22}' "/proc/$pid/stat" >"$A_START_FILE"
ps -o pgid= -p "$pid" | tr -d ' ' >"$A_PGID_FILE"
chmod 600 "$A_PID_FILE" "$A_PGID_FILE" "$A_START_FILE" "$A_LOG_FILE" 2>/dev/null || true
printf 'A_STARTED=1 SUPERVISOR_PID=%s PGID=%s START_TICKS=%s\n' "$pid" "$(cat "$A_PGID_FILE")" "$(cat "$A_START_FILE")"
