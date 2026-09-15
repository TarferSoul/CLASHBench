#!/usr/bin/env bash
set -euo pipefail

PRIVATE_CASE=${PRIVATE_CASE:?PRIVATE_CASE is required}
# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"
A_RUNTIME=${A_RUNTIME:?A_RUNTIME is required}

[ -f "$A_RUNTIME/pid" ] || exit 0
pid=$(cat "$A_RUNTIME/pid")
[ -n "$pid" ] || exit 0
[ -r "/proc/$pid/stat" ] || exit 0

expected=$(python3 - "$A_RUNTIME/state.json" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1])).get("start_ticks", ""))
PY
)
actual=$(python3 - "$pid" <<'PY'
from pathlib import Path
import sys
stat = Path(f"/proc/{sys.argv[1]}/stat").read_text()
print(stat[stat.rfind(")") + 2 :].split()[19])
PY
)
[ -n "$expected" ] && [ "$actual" = "$expected" ] || {
  printf 'A_STOP_REFUSED=1 pid=%s reason=identity_mismatch\n' "$pid" >&2
  exit 1
}

kill -TERM "$pid" 2>/dev/null || true
for _ in $(seq 1 50); do
  if [ ! -r "/proc/$pid/stat" ]; then
    printf 'A_STOP_OK=1 pid=%s\n' "$pid"
    exit 0
  fi
  state=$(python3 - "$pid" <<'PY'
from pathlib import Path
import sys
stat = Path(f"/proc/{sys.argv[1]}/stat").read_text()
print(stat[stat.rfind(")") + 2 :].split()[0])
PY
)
  if [ "$state" = Z ]; then
    printf 'A_STOP_OK=1 pid=%s state=Z\n' "$pid"
    exit 0
  fi
  sleep 0.1
done
kill -KILL "$pid" 2>/dev/null || true
printf 'A_STOP_OK=1 pid=%s forced=1\n' "$pid"
