#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
status=$(bash "$ROOT/a/status_a.sh")
grep -q 'ready=yes' <<<"$status" || { echo "TRUST_OK=0 reason=a_not_ready status=$status"; exit 1; }
run_dir=$(readlink -f "$A_RUN_ROOT/current")
pid=$(cat "$run_dir/launcher.pid")
starttime=$(awk '{print $22}' "/proc/$pid/stat")
pgid=$(ps -o pgid= -p "$pid" | tr -d ' ')
sid=$(ps -o sid= -p "$pid" | tr -d ' ')
rss_kib=$(awk '/^VmRSS:/{print $2+0}' "/proc/$pid/status")
pss_kib=$(setpriv --reuid=agentb --regid=agentb --init-groups \
  awk '/^Pss:/{print $2+0}' "/proc/$pid/smaps_rollup")
inputs_sha256=$(sha256sum "$run_dir/inputs.sha256" | awk '{print $1}')

python3 - "$run_dir/latest_generation.json" "$run_dir/phase.json" "$A_TRUST_FILE" \
  "$pid" "$starttime" "$pgid" "$sid" "$rss_kib" "$pss_kib" "$inputs_sha256" "$run_dir" <<'PY'
import json, shlex, sys
latest = json.load(open(sys.argv[1]))
phase = json.load(open(sys.argv[2]))
values = {
    "A_TRUST_PID": int(sys.argv[4]),
    "A_TRUST_STARTTIME": int(sys.argv[5]),
    "A_TRUST_PGID": int(sys.argv[6]),
    "A_TRUST_SID": int(sys.argv[7]),
    "A_TRUST_RSS_KIB": int(sys.argv[8]),
    "A_TRUST_PSS_KIB": int(sys.argv[9]),
    "A_TRUST_INPUTS_SHA256": sys.argv[10],
    "A_RUN_DIR": sys.argv[11],
    "A_BASELINE_GENERATION": int(latest["generation"]),
    "A_BASELINE_DIGEST": latest["replacement_digest"],
    "A_SOURCE_SHA256": latest["source_sha256"],
    "A_CAPTURE_PHASE": phase["phase"],
}
with open(sys.argv[3], "w") as handle:
    for key, value in values.items():
        handle.write(f"{key}={shlex.quote(str(value))}\n")
PY
chmod 600 "$A_TRUST_FILE"
echo "TRUST_OK=1 pid=$pid starttime=$starttime pgid=$pgid sid=$sid baseline_generation=$(awk -F= '$1=="A_BASELINE_GENERATION"{print $2}' "$A_TRUST_FILE") rss_kib=$rss_kib pss_kib=$pss_kib run=$run_dir"
