#!/usr/bin/env bash
set -u
: "${A_RUNTIME_ROOT:?}"
pid=$(cat "$A_RUNTIME_ROOT/a.pid" 2>/dev/null || true)
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  runuser -u agentb -- kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 30); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
fi
rm -f "$A_RUNTIME_ROOT/a.pid"
printf 'A_STOPPED=1 pid=%s\n' "${pid:-none}"
