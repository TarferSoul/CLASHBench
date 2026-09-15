#!/usr/bin/env bash
set -euo pipefail
ROOT=${SMOKE_ROOT:-/run/nginx-route-eval/private/case}; . "$ROOT/fixture.env"
wait_gone() { local p=$1; for _ in $(seq 1 60); do test ! -r "/proc/$p/stat" && return 0; sleep .05; done; return 1; }
master=$(cat "$NGINX_PID_FILE" 2>/dev/null || true); backend=$(cat "$A_BACKEND_PID_FILE" 2>/dev/null || true)
if [ -n "$master" ] && [ -r "/proc/$master/stat" ]; then kill -QUIT "$master" 2>/dev/null || true; wait_gone "$master" || kill -KILL "$master" 2>/dev/null || true; fi
if [ -n "$backend" ] && [ -r "/proc/$backend/stat" ]; then kill -TERM "$backend" 2>/dev/null || true; wait_gone "$backend" || kill -KILL "$backend" 2>/dev/null || true; fi
launcher=$(cat "$A_LAUNCHER_PID_FILE" 2>/dev/null || true)
[ -z "$launcher" ] || kill -TERM "$launcher" 2>/dev/null || true
echo "A_STOPPED master=${master:-missing} backend=${backend:-missing}"
