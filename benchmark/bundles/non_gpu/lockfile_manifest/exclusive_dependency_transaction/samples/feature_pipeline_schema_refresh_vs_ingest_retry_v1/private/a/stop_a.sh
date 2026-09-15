#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?CASE_PRIVATE_ROOT must be set}"
. "$CASE_PRIVATE_ROOT/lib/runtime.sh"

python3 - "$TRUST_FILE" "$PROJECT_ROOT/.depctl/transaction-owner.json" "$PROJECT_ROOT/.depctl/runs/current/launcher.pid" > /tmp/schema_refresh_stop_target.$$ <<'PY'
import json
import pathlib
import sys

trust_path, owner_path, launcher_path = map(pathlib.Path, sys.argv[1:])
payload = {}
for path in (trust_path, owner_path):
    if path.exists():
        try:
            payload = json.loads(path.read_text())
            break
        except Exception:
            pass
pid = payload.get("pid")
pgid = payload.get("pgid")
if not pid and launcher_path.exists():
    pid = launcher_path.read_text().strip()
print(f"pid={pid or ''}")
print(f"pgid={pgid or ''}")
PY
. /tmp/schema_refresh_stop_target.$$
rm -f /tmp/schema_refresh_stop_target.$$

if [ -n "${pgid:-}" ] && [ "$pgid" != "$(ps -o pgid= -p $$ | tr -d ' ')" ]; then
  kill -TERM "-$pgid" 2>/dev/null || true
elif [ -n "${pid:-}" ]; then
  kill -TERM "$pid" 2>/dev/null || true
fi

for _ in $(seq 1 40); do
  alive=0
  if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
    alive=1
  fi
  [ "$alive" = 0 ] && break
  sleep 0.1
done
if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
  if [ -n "${pgid:-}" ]; then
    kill -KILL "-$pgid" 2>/dev/null || true
  else
    kill -KILL "$pid" 2>/dev/null || true
  fi
fi
rm -f "$PROJECT_ROOT/.depctl/transaction-owner.json"
echo "A_STOPPED pid=${pid:-} pgid=${pgid:-}"
