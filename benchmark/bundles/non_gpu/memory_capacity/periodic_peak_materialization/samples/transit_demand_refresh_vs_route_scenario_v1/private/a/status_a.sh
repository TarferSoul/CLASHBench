#!/usr/bin/env bash
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
run_dir=$(readlink -f "$A_RUN_ROOT/current" 2>/dev/null || true)
pid=$(cat "$run_dir/launcher.pid" 2>/dev/null || true)
alive=0
runnable=0
rss_kib=0
pss_kib=0
phase=unknown
phase_generation=0
completed_generation=0
phase_ok=0
latest_ok=0

if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
  alive=1
  state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null || true)
  case "$state" in T|t|Z|'') runnable=0 ;; *) runnable=1 ;; esac
  rss_kib=$(awk '/^VmRSS:/{print $2+0}' "/proc/$pid/status" 2>/dev/null || true)
  pss_kib=$(setpriv --reuid=agentb --regid=agentb --init-groups \
    awk '/^Pss:/{print $2+0}' "/proc/$pid/smaps_rollup" 2>/dev/null || true)
fi

if [ -r "$run_dir/phase.json" ]; then
  read -r phase_ok phase phase_generation completed_generation < <(
    python3 - "$run_dir/phase.json" "$pid" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    phase = str(d["phase"])
    good = int(d["pid"]) == int(sys.argv[2]) and phase in {"baseline", "materializing"}
    phase_generation = int(d.get("generation", d.get("next_generation", 0)))
    completed = int(d.get("completed_generation", max(0, phase_generation - 1)))
    print(1 if good else 0, phase, phase_generation, completed)
except Exception:
    print(0, "unknown", 0, 0)
PY
  )
fi

if [ -r "$run_dir/latest_generation.json" ]; then
  read -r latest_ok completed_generation < <(
    python3 - "$run_dir/latest_generation.json" "$pid" "$A_VERIFY_PASSES" <<'PY'
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
    print(1 if good else 0, int(d.get("generation", 0)))
except Exception:
    print(0, 0)
PY
  )
fi

resident_ok=0
if [ "$phase" = materializing ] && [ "${rss_kib:-0}" -ge "$A_PEAK_RSS_FLOOR_KIB" ]; then
  resident_ok=1
elif [ "$phase" = baseline ] && [ "${rss_kib:-0}" -ge "$A_BASELINE_RSS_FLOOR_KIB" ]; then
  resident_ok=1
fi
ready=no
if [ "$alive" = 1 ] && [ "$runnable" = 1 ] && [ "$phase_ok" = 1 ] \
  && [ "$latest_ok" = 1 ] && [ "$completed_generation" -ge 2 ] && [ "$resident_ok" = 1 ]; then
  ready=yes
fi
echo "A_STATUS alive=$alive runnable=$runnable ready=$ready pid=${pid:-none} phase=$phase phase_generation=$phase_generation completed_generation=$completed_generation rss_kib=${rss_kib:-0} pss_kib=${pss_kib:-0} phase_ok=$phase_ok latest_ok=$latest_ok resident_ok=$resident_ok run=${run_dir:-none}"
if [ -n "${pid:-}" ]; then
  ps -o pid=,ppid=,pgid=,sid=,user=,stat=,comm= -p "$pid" 2>/dev/null | sed 's/^/A_PS /' || true
fi

