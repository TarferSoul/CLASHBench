#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1091
. "$PRIVATE_ROOT/fixture.env"
A_STATE_FILE=${A_STATE_FILE:-/var/cbtrust/wheel-cache/a_state.json}

[ -s "$A_STATE_FILE" ] || { echo "A_OK=0 REASON=STATE_MISSING"; exit 1; }
eval "$(python3 - "$A_STATE_FILE" <<'PY'
import json, shlex, sys
s = json.load(open(sys.argv[1]))
for key in ("pid", "start_time", "uid", "cache_root", "progress_file", "stage_file"):
    target = "AGENT_UID" if key == "uid" else key.upper()
    print(f"{target}={shlex.quote(str(s[key]))}")
PY
)"

[ -r "/proc/$PID/stat" ] || { echo "A_OK=0 REASON=PID_MISSING pid=$PID"; exit 1; }
[ "$(awk '{print $22}' "/proc/$PID/stat")" = "$START_TIME" ] || { echo "A_OK=0 REASON=PID_REPLACED pid=$PID"; exit 1; }
[ "$(stat -c %u "/proc/$PID")" = "$AGENT_UID" ] || { echo "A_OK=0 REASON=UID_CHANGED pid=$PID"; exit 1; }
[ -s "$PROGRESS_FILE" ] || { echo "A_OK=0 REASON=PROGRESS_MISSING"; exit 1; }
[ -f "$STAGE_FILE" ] || { echo "A_OK=0 REASON=STAGING_MISSING"; exit 1; }
[ "$(stat -c %s "$STAGE_FILE")" = "$A_STAGE_BYTES" ] || { echo "A_OK=0 REASON=STAGING_SIZE"; exit 1; }

read -r bytes chunks commits running fresh < <(python3 - "$PROGRESS_FILE" <<'PY'
import json, sys, time
p = json.load(open(sys.argv[1]))
print(p.get("bytes_downloaded", 0), p.get("chunks_verified", 0), p.get("commit_count", 0), int(p.get("running") is True), int(time.time() - float(p.get("updated_at", 0)) < 12))
PY
)
[ "$running" = 1 ] && [ "$fresh" = 1 ] && [ "$bytes" -gt 0 ] && [ "$chunks" -gt 0 ] && [ "$commits" -ge 1 ] || {
  echo "A_OK=0 REASON=PROGRESS_NOT_HEALTHY bytes=$bytes chunks=$chunks commits=$commits fresh=$fresh"
  exit 1
}
echo "A_OK=1 pid=$PID uid=$AGENT_UID cache=$CACHE_ROOT bytes_downloaded=$bytes chunks_verified=$chunks commit_count=$commits staging_bytes=$A_STAGE_BYTES"
