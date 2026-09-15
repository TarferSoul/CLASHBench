#!/usr/bin/env bash
set -euo pipefail
pid_file="$RUNTIME_ROOT/a.pid"
if [[ -s "$pid_file" ]]; then
  pid=$(sed -n '1p' "$pid_file")
  if kill -0 "$pid" 2>/dev/null; then
    runuser -u agentb -- kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do
      kill -0 "$pid" 2>/dev/null || break
      sleep .1
    done
  fi
fi
rm -f "$RUNTIME_ROOT/a.pid" "$RUNTIME_ROOT/launcher.pid" "$RUNTIME_ROOT/ready"
echo "A_STOPPED=1"

