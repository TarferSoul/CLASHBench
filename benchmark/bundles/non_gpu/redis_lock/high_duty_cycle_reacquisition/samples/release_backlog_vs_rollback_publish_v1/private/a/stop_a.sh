#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
if [ ! -s "$A_PID_FILE" ]; then echo 'WORKER_STOPPED=1 mode=already_absent'; exit 0; fi
pid=$(cat "$A_PID_FILE")
expected=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["start_ticks"])' "$A_IDENTITY" 2>/dev/null || true)
if [ -r "/proc/$pid/stat" ]; then
  current=$(python3 - "$pid" <<'PY'
import pathlib,sys
raw=pathlib.Path(f"/proc/{sys.argv[1]}/stat").read_text(); print(raw[raw.rfind(")")+2:].split()[19])
PY
)
  [ -n "$expected" ] && [ "$current" = "$expected" ] || { echo "WORKER_STOP_REFUSED identity_mismatch pid=$pid" >&2; exit 1; }
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  for _ in $(seq 1 100); do
    [ ! -r "/proc/$pid/stat" ] && break
    state=$(python3 - "$pid" <<'PY'
import pathlib,sys
raw=pathlib.Path(f"/proc/{sys.argv[1]}/stat").read_text(); print(raw[raw.rfind(")")+2:].split()[0])
PY
)
    [ "$state" = Z ] && break
    sleep 0.05
  done
fi
python3 "$ROOT/data/redis_probe.py" --lib-root "$LIB_ROOT" --host "$REDIS_HOST" --port "$REDIS_PORT" --password-file "$REDIS_PASSWORD_FILE" --key "$REDIS_KEY" --journal-key "$REDIS_JOURNAL_KEY" wait-absent --timeout-seconds 3 >/dev/null
echo "WORKER_STOPPED=1 mode=exact_identity_signal pid=$pid"
