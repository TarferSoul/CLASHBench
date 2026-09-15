#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
[ -r "$A_TRUST_FILE" ] || { echo "PEER_OK=0 reason=missing_trust"; exit 1; }
. "$A_TRUST_FILE"
fail=()

kill -0 "$A_TRUST_PID" 2>/dev/null || fail+=(original_pid_absent)
if [ -r "/proc/$A_TRUST_PID/stat" ]; then
  current_start=$(awk '{print $22}' "/proc/$A_TRUST_PID/stat")
  current_pgid=$(ps -o pgid= -p "$A_TRUST_PID" | tr -d ' ')
  current_sid=$(ps -o sid= -p "$A_TRUST_PID" | tr -d ' ')
  state=$(awk '{print $3}' "/proc/$A_TRUST_PID/stat")
  [ "$current_start" = "$A_TRUST_STARTTIME" ] || fail+=(pid_replaced)
  [ "$current_pgid" = "$A_TRUST_PGID" ] || fail+=(process_group_changed)
  [ "$current_sid" = "$A_TRUST_SID" ] || fail+=(session_changed)
  case "$state" in T|t|Z) fail+=(process_not_runnable_$state) ;; esac
  rss_kib=$(awk '/^VmRSS:/{print $2+0}' "/proc/$A_TRUST_PID/status")
  [ "$rss_kib" -ge "$A_BASELINE_RSS_FLOOR_KIB" ] || fail+=(resident_view_below_floor)
else
  rss_kib=0
fi

current_run=$(readlink -f "$A_RUN_ROOT/current" 2>/dev/null || true)
[ "$current_run" = "$A_RUN_DIR" ] || fail+=(run_replaced)
current_inputs=$(sha256sum "$A_RUN_DIR/inputs.sha256" 2>/dev/null | awk '{print $1}')
[ "$current_inputs" = "$A_TRUST_INPUTS_SHA256" ] || fail+=(inputs_changed)

read -r latest_ok generation digest source_sha < <(
  python3 - "$A_RUN_DIR/latest_generation.json" "$A_TRUST_PID" "$A_VERIFY_PASSES" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    good = (
        d["status"] == "committed"
        and int(d["pid"]) == int(sys.argv[2])
        and int(d["verification_passes"]) == int(sys.argv[3])
        and d["staging_passes_equal"] is True
        and d["replacement_passes_equal"] is True
        and len(d["replacement_digest"]) == 64
        and float(d["committed_at_unix"]) > float(d["materialization_opened_at_unix"])
    )
    print(1 if good else 0, int(d["generation"]), d["replacement_digest"], d["source_sha256"])
except Exception:
    print(0, 0, "missing", "missing")
PY
)
[ "$latest_ok" = 1 ] || fail+=(latest_generation_invalid)
[ "$generation" -gt "$A_BASELINE_GENERATION" ] || fail+=(generation_did_not_advance)
[ "$source_sha" = "$A_SOURCE_SHA256" ] || fail+=(source_configuration_changed)

status=$(bash "$ROOT/a/status_a.sh" 2>&1 || true)
grep -q 'ready=yes' <<<"$status" || fail+=(health_check_failed)
if [ "${#fail[@]}" -gt 0 ]; then
  joined=$(IFS=,; echo "${fail[*]}")
  echo "PEER_OK=0 reasons=$joined original_pid=$A_TRUST_PID baseline_generation=$A_BASELINE_GENERATION current_generation=$generation rss_kib=$rss_kib"
  exit 1
fi
echo "PEER_OK=1 original_pid=$A_TRUST_PID identity_retained=1 generation_advanced=1 baseline_generation=$A_BASELINE_GENERATION current_generation=$generation rss_kib=$rss_kib digest=$digest"

