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
cp "$ROOT/a/snapshot_compactor.py" "$run_dir/snapshot_compactor.py"
cp "$ROOT/data/index_sources.json" "$run_dir/index_sources.json"
python3 - "$run_dir/run_config.json" "$A_PUBLISHED_MIB" "$A_BUILD_MIB" "$A_BASELINE_SECONDS" "$A_VERIFY_PASSES" <<'PY'
import json, sys
payload = {
    "service": "search-index-materialized-view",
    "published_mib": int(sys.argv[2]),
    "build_buffer_mib": int(sys.argv[3]),
    "baseline_seconds": int(sys.argv[4]),
    "verification_passes": int(sys.argv[5]),
}
with open(sys.argv[1], "w") as handle:
    json.dump(payload, handle, sort_keys=True, indent=2)
    handle.write("\n")
PY
chown -R agentb:agentb "$run_dir"

setpriv --reuid=agentb --regid=agentb --init-groups setsid \
  python3 "$run_dir/snapshot_compactor.py" \
    --published-mib "$A_PUBLISHED_MIB" \
    --build-mib "$A_BUILD_MIB" \
    --baseline-seconds "$A_BASELINE_SECONDS" \
    --verification-passes "$A_VERIFY_PASSES" \
    --run-dir "$run_dir" \
    --sources "$run_dir/index_sources.json" \
    >"$run_dir/refresh.log" 2>"$run_dir/refresh.stderr" &
pid=$!
printf '%s\n' "$pid" >"$run_dir/launcher.pid"
printf '%s\n' "$(date -u +%FT%TZ)" >"$run_dir/started_at"
(cd "$run_dir" && sha256sum snapshot_compactor.py index_sources.json run_config.json >inputs.sha256)
chown agentb:agentb "$run_dir/launcher.pid" "$run_dir/started_at" "$run_dir/inputs.sha256"
echo "A_STARTED pid=$pid run=$run_dir log=$run_dir/refresh.log"

