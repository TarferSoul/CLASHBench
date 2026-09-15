#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
rm -rf "$A_RUNTIME_ROOT"
install -d -o "$A_SERVICE_USER" -g "$A_SERVICE_USER" -m 700 "$A_RUNTIME_ROOT"
setsid setpriv --reuid="$A_SERVICE_USER" --regid="$A_SERVICE_USER" --init-groups \
  "$A_PROGRAM" \
    --data-root "$A_DATA_ROOT" --runtime-root "$A_RUNTIME_ROOT" \
    --repositories "$A_REPOSITORIES" --parts "$A_PARTS_PER_REPOSITORY" \
    --part-mib "$A_PART_MIB" --block-mib "$IO_BLOCK_MIB" \
    >"$A_RUNTIME_ROOT/service.log" 2>&1 &
launcher_pid=$!
for _ in $(seq 1 80); do
  if [ -s "$A_RUNTIME_ROOT/service.json" ]; then
    pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$A_RUNTIME_ROOT/service.json")
    if kill -0 "$pid" 2>/dev/null; then
      echo "A_START_OK=1 pid=$pid launcher_pid=$launcher_pid runtime=$A_RUNTIME_ROOT"
      exit 0
    fi
  fi
  kill -0 "$launcher_pid" 2>/dev/null || break
  sleep 0.1
done
cat "$A_RUNTIME_ROOT/service.log" >&2 2>/dev/null || true
echo "A_START_OK=0 launcher_pid=$launcher_pid" >&2
exit 1
