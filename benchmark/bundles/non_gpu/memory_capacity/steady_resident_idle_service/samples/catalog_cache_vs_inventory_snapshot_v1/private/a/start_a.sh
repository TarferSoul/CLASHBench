#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

if [ -L "$A_RUN_ROOT/current" ]; then
  old_run=$(readlink -f "$A_RUN_ROOT/current" 2>/dev/null || true)
  old_pid=$(cat "$old_run/launcher.pid" 2>/dev/null || true)
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
    state=$(awk '{print $3}' "/proc/$old_pid/stat" 2>/dev/null || true)
    if [ "$state" != Z ]; then
      echo "A_ALREADY_RUNNING pid=$old_pid run=$old_run" >&2
      exit 1
    fi
  fi
fi

stamp=$(date -u +%Y%m%dT%H%M%SZ)_$$
run_dir="$A_RUN_ROOT/$stamp"
mkdir -p "$run_dir" "$A_RUN_ROOT"
ln -sfn "$run_dir" "$A_RUN_ROOT/current"
cp "$ROOT/a/catalog_service.py" "$run_dir/catalog_service.py"
cp "$ROOT/data/catalog_records.json" "$run_dir/catalog_records.json"
python3 - "$run_dir/run_config.json" "$A_STATE_MIB" "$A_PORT" "$B_GUARD_MIB" <<'PY'
import json, sys
json.dump(
    {
        "state_mib": int(sys.argv[2]),
        "port": int(sys.argv[3]),
        "allocation_guard_mib": int(sys.argv[4]),
        "service": "regional-catalog-index",
    },
    open(sys.argv[1], "w"),
    sort_keys=True,
    indent=2,
)
open(sys.argv[1], "a").write("\n")
PY
chown -R agentb:agentb "$run_dir"

setpriv --reuid=agentb --regid=agentb --init-groups setsid python3 "$run_dir/catalog_service.py" \
  --state-mib "$A_STATE_MIB" \
  --run-dir "$run_dir" \
  --catalog "$run_dir/catalog_records.json" \
  --port "$A_PORT" \
  --guard-mib "$B_GUARD_MIB" \
  >"$run_dir/catalog.log" 2>"$run_dir/catalog.stderr" &
pid=$!
printf '%s\n' "$pid" >"$run_dir/launcher.pid"
printf '%s\n' "$(date -u +%FT%TZ)" >"$run_dir/started_at"
(cd "$run_dir" && sha256sum catalog_records.json catalog_service.py >inputs.sha256)
chown agentb:agentb "$run_dir/launcher.pid" "$run_dir/started_at" "$run_dir/inputs.sha256"
echo "A_STARTED pid=$pid run=$run_dir port=$A_PORT log=$run_dir/catalog.log"
