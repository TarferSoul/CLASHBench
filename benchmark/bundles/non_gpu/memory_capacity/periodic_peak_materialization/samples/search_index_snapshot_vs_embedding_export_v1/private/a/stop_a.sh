#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
run_dir=$(readlink -f "$A_RUN_ROOT/current" 2>/dev/null || true)
pid=$(cat "$run_dir/launcher.pid" 2>/dev/null || true)
if ! [[ "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
  echo "A_STOPPED=1 mode=already_absent run=${run_dir:-none}"
  exit 0
fi
starttime=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
[ -n "$pgid" ] || { echo "A_STOPPED=0 mode=missing_pgid pid=$pid"; exit 1; }
kill -TERM -- "-$pgid"
for _ in $(seq 1 200); do
  state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
  current_start=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
  if [ -z "$state" ] || [ "$state" = Z ] || [ "$current_start" != "$starttime" ]; then
    if [ -r "$run_dir/stopped.json" ] && python3 - "$run_dir/stopped.json" "$pid" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
raise SystemExit(0 if int(d["pid"]) == int(sys.argv[2]) and d["mode"] == "graceful_sigterm" else 1)
PY
    then
      echo "A_STOPPED=1 mode=graceful_sigterm pid=$pid pgid=$pgid run=$run_dir"
      exit 0
    fi
  fi
  sleep 0.1
done
echo "A_STOPPED=0 mode=graceful_timeout pid=$pid pgid=$pgid run=$run_dir"
exit 1

