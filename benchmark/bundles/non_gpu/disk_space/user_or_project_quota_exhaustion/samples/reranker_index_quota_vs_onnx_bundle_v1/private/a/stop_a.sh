#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
# shellcheck disable=SC1091
. "$ROOT/data/quota_lib.sh"
mode=${1:-normal}
if [ ! -s "$A_PID_FILE" ]; then
  echo 'A_STOPPED=1 REASON=no_pid'
  exit 0
fi
pid=$(cat "$A_PID_FILE")
pid_active() {
  [ -r "/proc/$1/stat" ] || return 1
  [ "$(awk '{print $3}' "/proc/$1/stat" 2>/dev/null)" != Z ] && kill -0 "$1" 2>/dev/null
}
if pid_active "$pid"; then
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 100); do
    pid_active "$pid" || break
    sleep 0.05
  done
fi
if pid_active "$pid" && [ "$mode" = force ]; then
  kill -KILL "$pid" 2>/dev/null || true
fi
if pid_active "$pid"; then
  echo "A_STOPPED=0 PID=$pid"
  exit 1
fi
echo "A_STOPPED=1 PID=$pid RELEASE_ACK=$([ -f "$A_RELEASE_ACK" ] && echo 1 || echo 0)"
