#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
. "$TOPOLOGY_ENV"
label=${1:?trial label required}
evidence=${2:?evidence directory required}
mkdir -p "$evidence"; chmod 700 "$evidence"
rm -rf "$B_OUTPUT_REAL"; install -d -o "$AGENT_UID" -g "$AGENT_GID" -m 755 "$B_OUTPUT_REAL"
stop_file="$evidence/${label}.stop"; rm -f "$stop_file"
taskset -c "$MONITOR_CPU" python3 "$ROOT/oracle/metric_sampler.py" --topology "$TOPOLOGY_ENV" \
  --output "$evidence/${label}_metrics.jsonl" --stop-file "$stop_file" --interval "$METRIC_INTERVAL_SECONDS" &
sampler_pid=$!
command=(taskset -c "$B_CPU" setpriv --reuid="$AGENT_UID" --regid="$AGENT_GID" --init-groups \
  "$B_PROGRAM" --job "$B_JOB" --placement "$B_PLACEMENT" --input "$B_INPUT_ROOT" --output "$B_OUTPUT_REAL")
if [ -s "$B_ACCEPTANCE" ]; then command+=(--acceptance "$B_ACCEPTANCE"); fi
set +e
if command -v perf >/dev/null 2>&1 && perf stat -e cycles -- true >/dev/null 2>&1; then
  perf stat -x, -o "$evidence/${label}_perf.csv" -e cycles,instructions,cache-references,cache-misses -- \
    "${command[@]}" >"$evidence/${label}.stdout" 2>"$evidence/${label}.stderr"
  rc=$?
else
  echo "PERF_COUNTERS=unavailable" >"$evidence/${label}_perf.txt"
  "${command[@]}" >"$evidence/${label}.stdout" 2>"$evidence/${label}.stderr"
  rc=$?
fi
set -e
touch "$stop_file"; wait "$sampler_pid"
printf '%s\n' "$rc" >"$evidence/${label}.rc"
if [ -f "$B_OUTPUT_REAL/$B_REPORT_NAME" ]; then cp "$B_OUTPUT_REAL/$B_REPORT_NAME" "$evidence/${label}_report.json"; fi
find "$B_OUTPUT_REAL" -maxdepth 1 -type f -printf '%f\n' | sort >"$evidence/${label}_outputs.txt"
if [ "$rc" -ne 0 ] || [ ! -s "$evidence/${label}_report.json" ]; then
  cat "$evidence/${label}.stderr" >&2 || true
  echo "TRIAL_OK=0 label=$label rc=$rc"; exit 1
fi
rate=$(python3 - "$evidence/${label}_report.json" "$RATE_KEY" <<'PY'
import json, pathlib, sys
print(f"{float(json.loads(pathlib.Path(sys.argv[1]).read_text())[sys.argv[2]]):.6f}")
PY
)
echo "TRIAL_OK=1 label=$label cpu=$B_CPU rate=$rate unit=$RATE_UNIT"
