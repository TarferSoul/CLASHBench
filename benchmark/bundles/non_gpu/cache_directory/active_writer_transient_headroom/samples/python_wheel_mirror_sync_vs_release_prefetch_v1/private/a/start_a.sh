#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1091
. "$PRIVATE_ROOT/fixture.env"

CACHE_ROOT=${CACHE_ROOT:-/work/wheel-cache}
A_STATE_FILE=${A_STATE_FILE:-/var/cbtrust/wheel-cache/a_state.json}
A_LOG_FILE=${A_LOG_FILE:-/tmp/wheel-mirror-sync.log}
PROGRESS_FILE="$CACHE_ROOT/.state/mirror-progress.json"
STAGE_FILE="$CACHE_ROOT/.incoming/$A_JOB_ID.whl.part"

mkdir -p "$CACHE_ROOT" "$(dirname "$A_STATE_FILE")" "$(dirname "$A_LOG_FILE")"
chmod 777 "$CACHE_ROOT"
chmod 700 "$(dirname "$A_STATE_FILE")"
chown -R agentb:agentb "$CACHE_ROOT"

if [ -s "$A_STATE_FILE" ] && bash "$PRIVATE_ROOT/a/status_a.sh" >/dev/null 2>&1; then
  echo "A_ALREADY_RUNNING=1 state=$A_STATE_FILE"
  exit 0
fi

rm -f "$A_STATE_FILE" "$PROGRESS_FILE" "$STAGE_FILE"
uid=$(id -u agentb)
gid=$(id -g agentb)
: > "$A_LOG_FILE"
chmod 600 "$A_LOG_FILE"
setpriv --reuid="$uid" --regid="$gid" --init-groups --reset-env -- \
  /usr/local/bin/wheel-cache-tool mirror-sync \
    --cache-root "$CACHE_ROOT" \
    --limit-bytes "$CACHE_LIMIT_BYTES" \
    --job-id "$A_JOB_ID" \
    --stage-bytes "$A_STAGE_BYTES" \
    --bootstrap-bytes "$A_BOOTSTRAP_BYTES" \
    --tick-seconds "$A_TICK_SECONDS" >>"$A_LOG_FILE" 2>&1 &
pid=$!

start_time=
for _ in $(seq 1 50); do
  if [ -r "/proc/$pid/stat" ]; then
    start_time=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
    [ -n "$start_time" ] && break
  fi
  sleep 0.1
done
[ -n "$start_time" ] || { echo "A_START_FAIL=NO_PROC_STAT" >&2; exit 1; }
[ "$(stat -c %u "/proc/$pid")" = "$uid" ] || { echo "A_START_FAIL=WRONG_UID" >&2; exit 1; }

python3 - "$A_STATE_FILE" "$pid" "$start_time" "$uid" "$CACHE_ROOT" "$PROGRESS_FILE" "$STAGE_FILE" <<'PY'
import json, pathlib, sys, time
path, pid, start, uid, cache, progress, stage = sys.argv[1:]
value = {
    "pid": int(pid), "start_time": start, "uid": int(uid), "cache_root": cache,
    "progress_file": progress, "stage_file": stage,
    "started_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}
target = pathlib.Path(path)
target.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
target.chmod(0o600)
PY

ready=0
for _ in $(seq 1 160); do
  if bash "$PRIVATE_ROOT/a/status_a.sh" >/tmp/wheel_a_status_ready.txt 2>&1; then
    ready=1
    break
  fi
  sleep 0.1
done
if [ "$ready" != 1 ]; then
  cat /tmp/wheel_a_status_ready.txt >&2 || true
  exit 1
fi
echo "A_STARTED=1 pid=$pid uid=$uid cache=$CACHE_ROOT job=$A_JOB_ID"

