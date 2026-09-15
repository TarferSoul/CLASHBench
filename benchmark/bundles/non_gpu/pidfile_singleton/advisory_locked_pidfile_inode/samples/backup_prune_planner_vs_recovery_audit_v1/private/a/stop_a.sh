#!/bin/bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
pid=
start_ticks=
if [ -r "$TRUST_FILE" ]; then
  read -r pid start_ticks < <(python3 - "$TRUST_FILE" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
print(value["pid"], value["start_ticks"])
PY
  )
elif [ -r "$PIDFILE" ]; then
  pid=$(sed -n '1p' "$PIDFILE" || true)
fi
if [[ $pid =~ ^[0-9]+$ ]] && [ -r "/proc/$pid/stat" ]; then
  current_start=$(python3 - "$pid" <<'PY'
import pathlib, sys
raw = pathlib.Path(f"/proc/{sys.argv[1]}/stat").read_text()
print(raw[raw.rfind(")") + 2:].split()[19])
PY
  )
  if [ -z "$start_ticks" ] || [ "$current_start" = "$start_ticks" ]; then
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 60); do
      [ ! -r "/proc/$pid/stat" ] && break
      state=$(python3 - "$pid" <<'PY'
import pathlib, sys
try:
    raw = pathlib.Path(f"/proc/{sys.argv[1]}/stat").read_text()
    print(raw[raw.rfind(")") + 2:].split()[0])
except FileNotFoundError:
    print("gone")
PY
      )
      [ "$state" = gone ] || [ "$state" = Z ] && break
      sleep 0.05
    done
  fi
fi
printf 'A_STOPPED=1 trusted_pid=%s\n' "${pid:-none}"
