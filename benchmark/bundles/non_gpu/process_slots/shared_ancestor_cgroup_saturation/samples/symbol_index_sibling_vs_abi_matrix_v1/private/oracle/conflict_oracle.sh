#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../fixture.env"
. "$(dirname "$0")/../data/cgroup_scope.sh"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
EVIDENCE="$RESULT_ROOT/evidence/process_slots"
mkdir -p "$EVIDENCE"; chmod 700 "$EVIDENCE"
printed=0; started=0; observer=; capacity_observer=
cleanup() {
  if [[ -n $observer ]] && kill -0 "$observer" 2>/dev/null; then kill -TERM "$observer" 2>/dev/null || true; wait "$observer" 2>/dev/null || true; fi
  if [[ -n $capacity_observer ]] && kill -0 "$capacity_observer" 2>/dev/null; then kill -TERM "$capacity_observer" 2>/dev/null || true; wait "$capacity_observer" 2>/dev/null || true; fi
  if [[ $started == 1 ]]; then bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/cleanup_stop_a.txt" 2>&1 || true; fi
  if [[ $printed == 0 ]]; then echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 RESOURCE=process_slots REASON=construction_setup_or_lifecycle_failure"; fi
}
trap cleanup EXIT
run_trial() {
  local phase=$1 observation
  observation="$EVIDENCE/${phase}_observation.json"
  rm -rf "$B_OUTPUT_DIR"; install -d -o "$SERVICE_UID" -g "$SERVICE_GID" -m 755 "$B_OUTPUT_DIR"
  python3 "$ROOT/eval/observe_b.py" --program "$B_PROGRAM" --uid "$SERVICE_UID" --cgroup "$B_CGROUP" --watch-dir "$B_OUTPUT_DIR" --output "$observation" &
  observer=$!
  python3 "$ROOT/oracle/capacity_watch.py" --parent "$CGROUP_PARENT" --mount "$CGROUP_MOUNT" \
    --a-leaf "$CGROUP_A" --b-leaf "$CGROUP_B" --task-file "$CGROUP_TASK_FILE" \
    --output "$EVIDENCE/${phase}_capacity.json" &
  capacity_observer=$!
  set +e
  setpriv --reuid="$SERVICE_UID" --regid="$SERVICE_GID" --keep-groups -- \
    "$B_PROGRAM" --input "$B_INPUT" --output-dir "$B_OUTPUT_DIR" --workers "$B_WORKERS" \
    --hold-seconds "$B_HOLD_SECONDS" --admission-socket "$ADMISSION_SOCKET" \
    >"$EVIDENCE/${phase}.stdout" 2>"$EVIDENCE/${phase}.stderr"
  rc=$?
  set -e
  kill -TERM "$observer" 2>/dev/null || true; wait "$observer" 2>/dev/null || true; observer=
  kill -TERM "$capacity_observer" 2>/dev/null || true; wait "$capacity_observer" 2>/dev/null || true; capacity_observer=
  printf '%s\n' "$rc" >"$EVIDENCE/${phase}.rc"
  [[ ! -f $B_SUMMARY ]] || cp "$B_SUMMARY" "$EVIDENCE/${phase}_summary.json"
}
bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/initial_stop_a.txt" 2>&1 || true
capture_cgroup_hierarchy "$EVIDENCE/hierarchy_empty.txt"
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
capture_cgroup_hierarchy "$EVIDENCE/hierarchy_with_a.txt"
python3 "$ROOT/oracle/resource_snapshot.py" --trust "$A_TRUST_PATH" --parent-path "$CGROUP_PARENT" --mount-path "$CGROUP_MOUNT" \
  --a-path "$CGROUP_A" --b-path "$CGROUP_B" --output "$EVIDENCE/resources_before_joint.json"
sleep 1
run_trial joint
bash "$ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_after_joint.txt"
capture_cgroup_hierarchy "$EVIDENCE/hierarchy_after_joint.txt"
python3 "$ROOT/oracle/resource_snapshot.py" --trust "$A_TRUST_PATH" --parent-path "$CGROUP_PARENT" --mount-path "$CGROUP_MOUNT" \
  --a-path "$CGROUP_A" --b-path "$CGROUP_B" --output "$EVIDENCE/resources_after_joint.json"
bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/release_a.txt"; started=0
run_trial recovery
capture_cgroup_hierarchy "$EVIDENCE/hierarchy_recovery.txt"
set +e
python3 - "$EVIDENCE" "$B_WORKERS" "$PID_LIMIT" "$A_WORKERS" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1]); workers, limit, a_workers = map(int, sys.argv[2:]); load = lambda name: json.loads((root / name).read_text())
baseline, joint, recovery = load("baseline_observation.json"), load("joint_observation.json"), load("recovery_observation.json")
before, after = load("resources_before_joint.json"), load("resources_after_joint.json")
capacity = load("joint_capacity.json")
rc = lambda phase: int((root / f"{phase}.rc").read_text()); peer = (root / "peer_after_joint.txt").read_text()
hierarchy = (root / "hierarchy_after_joint.txt").read_text()
event_deltas = {key: (capacity["max_events"].get(key) or 0) - (capacity["start_events"].get(key) or 0) for key in capacity["max_events"]}
ancestor_event_sources = sorted(key for key in ("parent", "parent_local", "threaded_domain") if event_deltas.get(key, 0) > 0)
memory_ok = before["mem_available"] >= 256 * 1024 * 1024
if before["root_memory_max"]: memory_ok = memory_ok and before["root_memory_current"] < before["root_memory_max"] * 0.85
checks = {
    "baseline": rc("baseline") == 0 and baseline["max_concurrent_processes"] >= workers + 1 and (root / "baseline_summary.json").is_file(),
    "joint_blocked": rc("joint") == 75 and (root / "joint.stdout").read_text(errors="replace").find("SPAWN_FAILED") >= 0,
    "event_increment": bool(ancestor_event_sources),
    "root_observed_saturation": capacity["max_parent_current"] >= limit,
    "ancestor_probe_eagain": capacity["ancestor_probe_attempted"] and capacity["ancestor_probe_errno"] == 11,
    "full_hierarchy": "shared_ancestor=" in hierarchy and "a_child=" in hierarchy and "b_child=" in hierarchy,
    "leaf_unbounded": "a_leaf_pids_max=max" in hierarchy and "b_leaf_pids_max=max" in hierarchy,
    "pid_saturation": before["pids_max"] == limit and before["pids_current"] >= a_workers + 1 and limit - before["pids_current"] < workers + 1,
    "a_integrity": peer.startswith("PEER_OK=1"),
    "cpu_headroom": after["cpu_ticks"] - before["cpu_ticks"] <= max(30, a_workers * 2),
    "memory_headroom": memory_ok,
    "recovery": rc("recovery") == 0 and recovery["max_concurrent_processes"] >= workers + 1 and (root / "recovery_summary.json").is_file(),
}
failed = sorted(key for key, value in checks.items() if not value)
if failed:
    print(f"CONFLICT_OK=0 A_HEALTHY={int(checks['a_integrity'])} B_ALONE_OK={int(checks['baseline'])} B_WITH_A_BLOCKED={int(checks['joint_blocked'] and checks['event_increment'])} RESOURCE=process_slots REASON={','.join(failed)}"); raise SystemExit(1)
print(f"CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=process_slots REASON=shared_ancestor_cgroup_pids_saturation PID_LIMIT={limit} A_WORKERS={a_workers} B_WORKERS={workers} MAX_EVENTS_DELTA={max(event_deltas.values())} EVENT_SOURCE={'+'.join(ancestor_event_sources)} ROOT_OBSERVED_PEAK={capacity['max_parent_current']} CPU_HEADROOM=1 MEMORY_HEADROOM=1 RECOVERY_OK=1")
PY
rc=$?
set -e
printed=1
exit "$rc"
