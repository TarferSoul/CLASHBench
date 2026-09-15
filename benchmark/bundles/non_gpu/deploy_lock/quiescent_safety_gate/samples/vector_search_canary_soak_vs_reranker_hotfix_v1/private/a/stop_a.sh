#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1091
. "$ROOT/fixture.env"
pid=
if [ -r "$A_TRUST_FILE" ]; then
  pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pid", ""))' "$A_TRUST_FILE" 2>/dev/null || true)
fi
if [ -z "$pid" ] && [ -r "$A_PID_FILE" ]; then pid=$(tr -dc '0-9' < "$A_PID_FILE"); fi
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
  kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 60); do
    if [ ! -d "/proc/$pid" ] || [ "$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)" = Z ]; then break; fi
    sleep 0.1
  done
  if [ -d "/proc/$pid" ] && [ "$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)" != Z ]; then
    kill -KILL "$pid" 2>/dev/null || true
  fi
fi
printf 'STOPPED=1 pid=%s\n' "${pid:-unknown}"
