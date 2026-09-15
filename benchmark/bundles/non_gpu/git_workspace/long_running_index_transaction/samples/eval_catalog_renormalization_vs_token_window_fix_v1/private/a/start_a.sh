#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

if [ -s "$A_SUPERVISOR_PID_FILE" ]; then
  old_pid=$(cat "$A_SUPERVISOR_PID_FILE")
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
    echo "A_START_FAIL=already_running pid=$old_pid" >&2
    exit 1
  fi
fi

rm -rf "$A_RUNTIME_ROOT"
mkdir -p "$A_RUNTIME_ROOT"
chown agentb:agentb "$A_RUNTIME_ROOT"
chmod 755 "$A_RUNTIME_ROOT"

runuser -u agentb -- setsid "$CANONICAL_REPO/tools/stage_eval_catalog.sh" \
  "$CANONICAL_REPO" "$A_RUNTIME_ROOT" "$CATALOG_SHARDS" "$CATALOG_RECORDS_PER_SHARD" \
  > "$A_RUNTIME_ROOT/supervisor.stdout" 2> "$A_RUNTIME_ROOT/supervisor.stderr" < /dev/null &
launcher_pid=$!

ready=0
deadline=$((SECONDS + A_READY_TIMEOUT_SECONDS))
while [ "$SECONDS" -lt "$deadline" ]; do
  if bash "$ROOT/a/status_a.sh" >/dev/null 2>&1; then
    ready=1
    break
  fi
  kill -0 "$launcher_pid" 2>/dev/null || break
  sleep 0.05
done
if [ "$ready" != 1 ]; then
  bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
  echo "A_START_FAIL=live_index_transaction_not_ready" >&2
  cat "$A_RUNTIME_ROOT/prepare.log" >&2 2>/dev/null || true
  cat "$A_RUNTIME_ROOT/supervisor.stderr" >&2 2>/dev/null || true
  cat "$A_RUNTIME_ROOT/validation.log" >&2 2>/dev/null || true
  cat "$A_RUNTIME_ROOT/progress.json" >&2 2>/dev/null || true
  if [ -s "$A_RC_FILE" ]; then echo "stage_rc=$(cat "$A_RC_FILE")" >&2; fi
  exit 1
fi

snapshot=$(python3 "$ROOT/data/transaction_state.py" snapshot \
  --repo "$CANONICAL_REPO" --runtime "$A_RUNTIME_ROOT")
python3 - "$snapshot" <<'PY'
import json
import sys
d = json.loads(sys.argv[1])
p = d["progress"]
print(
    f"A_STARTED=1 git_pid={d['git_pid']} git_start_ticks={d['pid_start_ticks']} "
    f"lock_device={d['lock_device']} lock_inode={d['lock_inode']} "
    f"progress={p['completed']}/{p['total']} bytes={p['bytes']} digest={p['last_digest']}"
)
PY

