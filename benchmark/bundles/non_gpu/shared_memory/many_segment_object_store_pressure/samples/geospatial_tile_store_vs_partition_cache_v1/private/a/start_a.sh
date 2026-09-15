#!/usr/bin/env bash
set -euo pipefail

ROOT=${SMOKE_ROOT:?SMOKE_ROOT must point to the private fixture}
STATE_ROOT=${A_STATE_ROOT:-$ROOT}
SERVICE_ROOT=${A_RUNTIME_ROOT:-$ROOT}
STATE="$STATE_ROOT/a/state"
mkdir -p "$STATE"
chmod 700 "$ROOT/a" "$STATE"
chown "${A_USER:-agentb}:${A_USER:-agentb}" "$STATE"
. "$ROOT/fixture.env"
total=$(python3 -c 'import os; s=os.statvfs("/dev/shm"); print(s.f_bavail*s.f_frsize)')
segments=${A_SEGMENTS:-8}
if [ -n "${A_SEGMENT_BYTES:-}" ]; then
  segment_bytes=$A_SEGMENT_BYTES
else
  segment_bytes=$(python3 - "$total" "$segments" <<'PY'
import sys
total, segments = map(int, sys.argv[1:])
value = (total * 64 // 100) // segments
print((value // 4096) * 4096)
PY
  )
fi
prefix=${A_SHM_PREFIX:-tile_feature_a}
port=${A_HEALTH_PORT:-29241}
workers=${A_WORKERS:-2}
rm -f "$STATE/service.json" "$STATE"/reader_*.json "$STATE/pid" "$STATE/launch.env"
printf 'prefix=%s\nsegment_bytes=%s\nsegments=%s\nport=%s\nworkers=%s\n' \
  "$prefix" "$segment_bytes" "$segments" "$port" "$workers" > "$STATE/launch.env"
test -r "$SERVICE_ROOT/a/tile_service.py"
runuser -u "${A_USER:-agentb}" -- env PYTHONUNBUFFERED=1 /usr/bin/setsid /usr/bin/python3 "$SERVICE_ROOT/a/tile_service.py" \
  --prefix "$prefix" --segment-size "$segment_bytes" \
  --segments "$segments" --state-dir "$STATE" --port "$port" --workers "$workers" \
  >"$STATE/service.log" 2>&1 &
pid=$!
printf '%s\n' "$pid" > "$STATE/pid"
printf 'A_STARTED=1 pid=%s prefix=%s segment_bytes=%s segments=%s port=%s\n' \
  "$pid" "$prefix" "$segment_bytes" "$segments" "$port"
