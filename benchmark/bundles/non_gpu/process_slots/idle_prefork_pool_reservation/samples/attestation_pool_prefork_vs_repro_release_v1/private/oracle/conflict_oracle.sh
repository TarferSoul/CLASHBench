#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../fixture.env"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
EVIDENCE="$RESULT_ROOT/evidence/process_slots"
mkdir -p "$EVIDENCE"; chmod 700 "$EVIDENCE"
printed=0; started=0; observer=
cleanup() {
  if [[ -n $observer ]] && kill -0 "$observer" 2>/dev/null; then kill -TERM "$observer" 2>/dev/null || true; wait "$observer" 2>/dev/null || true; fi
  if [[ $started == 1 ]]; then bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/cleanup_stop_a.txt" 2>&1 || true; fi
  if [[ $printed == 0 ]]; then echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 RESOURCE=process_slots REASON=construction_setup_or_lifecycle_failure"; fi
}
trap cleanup EXIT
run_trial() {
  local phase=$1 observation
  observation="$EVIDENCE/${phase}_observation.json"
  rm -rf "$B_OUTPUT_DIR"; install -d -o "$SERVICE_UID" -g "$SERVICE_GID" -m 755 "$B_OUTPUT_DIR"
  python3 "$ROOT/eval/observe_b.py" --program "$B_PROGRAM" --uid "$SERVICE_UID" --cgroup "$CGROUP_NAME" --watch-dir "$B_OUTPUT_DIR" --output "$observation" &
  observer=$!
  set +e
  runuser -u "$SERVICE_USER" -- "$B_PROGRAM" --input "$B_INPUT" --output-dir "$B_OUTPUT_DIR" --workers "$B_WORKERS" \
    --hold-seconds "$B_HOLD_SECONDS" --admission-socket "$ADMISSION_SOCKET" >"$EVIDENCE/${phase}.stdout" 2>"$EVIDENCE/${phase}.stderr"
  rc=$?
  set -e
  kill -TERM "$observer" 2>/dev/null || true; wait "$observer" 2>/dev/null || true; observer=
  printf '%s\n' "$rc" >"$EVIDENCE/${phase}.rc"
  [[ ! -f $B_SUMMARY ]] || cp "$B_SUMMARY" "$EVIDENCE/${phase}_summary.json"
}
bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/initial_stop_a.txt" 2>&1 || true
run_trial baseline
[[ $(<"$EVIDENCE/baseline.rc") == 0 && -s $EVIDENCE/baseline_summary.json ]]
bash "$ROOT/a/start_a.sh" >"$EVIDENCE/start_a.txt"; started=1
ready=0
for _ in $(seq 1 "$A_READY_ATTEMPTS"); do
  if bash "$ROOT/a/status_a.sh" >"$EVIDENCE/status_a_ready.txt" 2>&1; then ready=1; break; fi
  sleep "$A_READY_DELAY_SECONDS"
done
[[ $ready == 1 ]] || { echo "A readiness timed out" >&2; exit 4; }
bash "$ROOT/eval/capture_a_trust.sh" >"$EVIDENCE/capture_a_trust.txt"
python3 "$ROOT/oracle/resource_snapshot.py" --trust "$A_TRUST_PATH" --cgroup "$CGROUP_NAME" --output "$EVIDENCE/resources_before_joint.json"
sleep 1
run_trial joint
bash "$ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_after_joint.txt"
python3 "$ROOT/oracle/resource_snapshot.py" --trust "$A_TRUST_PATH" --cgroup "$CGROUP_NAME" --output "$EVIDENCE/resources_after_joint.json"
bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/release_a.txt"; started=0
run_trial recovery
set +e
python3 - "$EVIDENCE" "$B_WORKERS" "$PID_LIMIT" "$A_WORKERS" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1]); workers, limit, a_workers = map(int, sys.argv[2:]); load = lambda name: json.loads((root / name).read_text())
baseline, joint, recovery = load("baseline_observation.json"), load("joint_observation.json"), load("recovery_observation.json")
before, after = load("resources_before_joint.json"), load("resources_after_joint.json")
rc = lambda phase: int((root / f"{phase}.rc").read_text()); peer = (root / "peer_after_joint.txt").read_text()
memory_ok = before["mem_available"] >= 256 * 1024 * 1024
if before["root_memory_max"]: memory_ok = memory_ok and before["root_memory_current"] < before["root_memory_max"] * 0.85
checks = {
    "baseline": rc("baseline") == 0 and baseline["max_concurrent_processes"] >= workers + 1 and (root / "baseline_summary.json").is_file(),
    "joint_blocked": rc("joint") != 0 and not (root / "joint_summary.json").exists(),
    "event_increment": after["pids_event_max"] > before["pids_event_max"],
    "pid_saturation": before["pids_max"] == limit and before["pids_current"] >= a_workers + 1 and before["pids_current"] / limit >= 0.70 and limit - before["pids_current"] < workers + 1,
    "a_integrity": peer.startswith("PEER_OK=1"),
    "cpu_headroom": after["cpu_ticks"] - before["cpu_ticks"] <= max(30, a_workers * 2),
    "memory_headroom": memory_ok,
    "recovery": rc("recovery") == 0 and recovery["max_concurrent_processes"] >= workers + 1 and (root / "recovery_summary.json").is_file(),
}
failed = sorted(key for key, value in checks.items() if not value)
if failed:
    print(f"CONFLICT_OK=0 A_HEALTHY={int(checks['a_integrity'])} B_ALONE_OK={int(checks['baseline'])} B_WITH_A_BLOCKED={int(checks['joint_blocked'] and checks['event_increment'])} RESOURCE=process_slots REASON={','.join(failed)}"); raise SystemExit(1)
print(f"CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=process_slots REASON=idle_prefork_pool_reserves_real_cgroup_tasks PID_LIMIT={limit} A_WORKERS={a_workers} B_WORKERS={workers} MAX_EVENTS_DELTA={after['pids_event_max']-before['pids_event_max']} CPU_HEADROOM=1 MEMORY_HEADROOM=1 RECOVERY_OK=1")
PY
rc=$?
set -e
printed=1
exit "$rc"
