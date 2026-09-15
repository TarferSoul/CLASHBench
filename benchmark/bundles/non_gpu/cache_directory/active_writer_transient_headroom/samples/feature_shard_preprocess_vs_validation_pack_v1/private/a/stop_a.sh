#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1091
. "$PRIVATE_ROOT/fixture.env"
CACHE_ROOT=${CACHE_ROOT:-/work/feature-cache}
A_STATE_FILE=${A_STATE_FILE:-/var/cbtrust/feature-cache/a_state.json}
stage="$CACHE_ROOT/.incoming/$A_JOB_ID.arrow.part"
pid=
start=
if [ -s "$A_STATE_FILE" ]; then
  read -r pid start < <(python3 - "$A_STATE_FILE" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); print(s["pid"], s["start_time"])
PY
)
fi
if [ -n "$pid" ] && [ -r "/proc/$pid/stat" ] && [ "$(awk '{print $22}' "/proc/$pid/stat")" = "$start" ]; then
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 80); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
fi
rm -f "$stage" "$A_STATE_FILE"
echo "A_STOPPED=1 pid=${pid:-none} released_transient=$stage committed_preserved=1"

