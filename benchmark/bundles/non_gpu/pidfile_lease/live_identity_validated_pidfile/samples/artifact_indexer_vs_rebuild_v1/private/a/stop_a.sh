#!/bin/bash
set -u
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
pid=""
if [ -r "$A_PIDFILE" ]; then pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pid",""))' "$A_PIDFILE" 2>/dev/null || true); fi
if [[ "$pid" =~ ^[0-9]+$ ]] && [ -r "/proc/$pid/cmdline" ]; then
  cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)
  if [[ "$cmd" == *"/usr/local/bin/code-indexer"* ]] && [[ "$cmd" == *"--mode daemon"* ]]; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.04; done
    kill -KILL "$pid" 2>/dev/null || true
  fi
fi
rm -f "$A_LAUNCHER_FILE"
if [ -r "$A_PIDFILE" ]; then current=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pid",""))' "$A_PIDFILE" 2>/dev/null || true); [ -z "$pid" ] || [ "$current" = "$pid" ] && rm -f "$A_PIDFILE"; fi
echo "A_STOPPED=1"
