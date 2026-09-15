#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

mkdir -p "$A_RUN_ROOT"
chmod 755 "$A_RUN_ROOT"
if [ -L "$A_RUN_ROOT/current" ]; then
  old_run=$(readlink -f "$A_RUN_ROOT/current" 2>/dev/null || true)
  old_pid=$(python3 - "$old_run/service.json" <<'PY' 2>/dev/null || true
import json, sys
print(json.load(open(sys.argv[1])).get("pid", ""))
PY
  )
  if [[ $old_pid =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
    echo "A_ALREADY_RUNNING pid=$old_pid run=$old_run" >&2
    exit 1
  fi
fi

rm -f "/dev/shm/$A_SHM_NAME"
stamp=$(date -u +%Y%m%dT%H%M%SZ)_$$
run_dir="$A_RUN_ROOT/$stamp"
install -d -o agentb -g agentb -m 755 "$run_dir"
install -o agentb -g agentb -m 755 "$ROOT/a/embedding_service.py" "$run_dir/embedding_service.py"
ln -sfn "$run_dir" "$A_RUN_ROOT/current"

runuser -u agentb -- env PYTHONUNBUFFERED=1 setsid python3 "$run_dir/embedding_service.py" \
  --cache-name "$A_SHM_NAME" --cache-bytes "$A_CACHE_BYTES" \
  --state-dir "$run_dir" --port "$A_HEALTH_PORT" --workers "$A_WORKERS" \
  >"$run_dir/service.log" 2>&1 &
launcher_pid=$!
printf '%s\n' "$launcher_pid" >"$run_dir/launcher.pid"

for _ in $(seq 1 "$A_READY_ATTEMPTS"); do
  if [ -s "$run_dir/service.json" ]; then
    actual_pid=$(python3 - "$run_dir/service.json" <<'PY' 2>/dev/null || true
import json, sys
print(json.load(open(sys.argv[1])).get("pid", ""))
PY
    )
    if [[ $actual_pid =~ ^[0-9]+$ ]] && kill -0 "$actual_pid" 2>/dev/null; then
      printf '%s\n' "$actual_pid" >"$run_dir/service.pid"
      chown agentb:agentb "$run_dir/service.pid" "$run_dir/launcher.pid"
      echo "A_STARTED=1 pid=$actual_pid cache=$A_SHM_NAME bytes=$A_CACHE_BYTES workers=$A_WORKERS run=$run_dir"
      exit 0
    fi
  fi
  sleep "$A_READY_DELAY_SECONDS"
done

echo "A_START_FAILED launcher_pid=$launcher_pid run=$run_dir" >&2
tail -n 80 "$run_dir/service.log" >&2 || true
exit 1
