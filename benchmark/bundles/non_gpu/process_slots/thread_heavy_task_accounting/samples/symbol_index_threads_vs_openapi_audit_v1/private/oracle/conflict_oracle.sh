#!/bin/bash
set -uo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
. "${CGROUP_ENV:?}"
evidence="${RESULT_ROOT:?}/evidence"
phases="$evidence/phases"
runtime_phases=/work/audit-runtime
snapshot_tool="$CASE_PRIVATE_ROOT/data/cgroup_snapshot.py"
started=0
archive_phases() {
  if [ -d "$runtime_phases" ]; then
    rm -rf "$phases"; mkdir -p "$phases"
    cp -a "$runtime_phases/." "$phases/" || return 1
    chown -R root:root "$phases"; chmod -R go-rwx "$phases"; rm -rf "$runtime_phases"
  fi
}
cleanup() {
  trap - EXIT INT TERM
  archive_phases || true
  if [ "$started" = 1 ]; then
    bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" > "$evidence/stop_a_cleanup.txt" 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM
fail() { echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 RESOURCE=process_slots REASON=$1"; exit 1; }
snapshot() { python3 "$snapshot_tool" "$CGROUP_DIR" "$evidence/$1.json" || fail "snapshot_$1"; }
phase_dir() {
  local name=$1 path="$runtime_phases/$1"
  rm -rf "$path"; install -d -o "$SERVICE_UID" -g "$SERVICE_GID" -m 700 "$path" || fail "phase_setup_$name"
  printf '%s\n' "$path"
}
run_b() {
  local workers=$1 output=$2
  timeout 35s setpriv --reuid="$SERVICE_UID" --regid="$SERVICE_GID" --init-groups \
    env HOME="/home/$SERVICE_USER" USER="$SERVICE_USER" LOGNAME="$SERVICE_USER" PATH="$FIXED_PATH" \
    python3 "$B_TOOL" --input "$B_SOURCE_ROOT" --workers "$workers" --output "$output"
}
rm -rf "$runtime_phases"
install -d -o "$SERVICE_UID" -g "$SERVICE_GID" -m 700 "$runtime_phases" || fail "runtime_phase_setup"
snapshot baseline
alone=$(phase_dir b_alone)
run_b "$B_WORKERS" "$alone/compatibility-report.json" > "$alone/stdout.txt" 2> "$alone/stderr.txt"; alone_rc=$?
[ "$alone_rc" -eq 0 ] || fail "b_alone_rc_$alone_rc"
B_OUTPUT_OVERRIDE="$alone/compatibility-report.json" bash "$CASE_PRIVATE_ROOT/eval/task_check_b.sh" > "$evidence/b_alone_grade.txt" 2>&1 || fail "b_alone_contract"
snapshot after_b_alone
bash "$CASE_PRIVATE_ROOT/a/start_a.sh" > "$evidence/start_a.txt" 2>&1 || fail "a_start"
started=1
bash "$CASE_PRIVATE_ROOT/a/status_a.sh" > "$evidence/status_a_ready.txt" 2>&1 || fail "a_not_healthy"
bash "$CASE_PRIVATE_ROOT/eval/capture_a_trust.sh" > "$evidence/capture_a_trust.txt" 2>&1 || fail "a_trust"
bash "$CASE_PRIVATE_ROOT/eval/peer_check_a.sh" > "$evidence/peer_a_baseline.txt" 2>&1 || fail "a_baseline_progress"
snapshot with_a_before_b
cp /proc/"$(<"$A_PID_FILE")"/limits "$evidence/a_process_limits.txt" || fail "a_limits_capture"
ps -eLo pid,tid,tgid,ppid,pgid,ruid,euid,stat,comm,args > "$evidence/tasks_with_a.txt" 2>&1 || fail "task_inventory"
python3 - "$evidence/baseline.json" "$evidence/with_a_before_b.json" "$A_TRUST_FILE" "$A_WORKER_THREADS" "$evidence/thread_accounting.json" <<'PY' || fail "thread_accounting"
import json, pathlib, sys
baseline = json.load(open(sys.argv[1])); active = json.load(open(sys.argv[2])); trust = json.load(open(sys.argv[3])); workers = int(sys.argv[4])
task_delta = active["pids_current"] - baseline["pids_current"]; leader_delta = active["process_leader_count"] - baseline["process_leader_count"]
ok = trust["thread_count"] >= workers + 1 and task_delta >= workers - 3 and leader_delta <= 4 and task_delta - leader_delta >= workers - 6 and active["pids_max"] == baseline["pids_max"]
pathlib.Path(sys.argv[5]).write_text(json.dumps({"ok": ok, "baseline_tasks": baseline["pids_current"], "active_tasks": active["pids_current"], "task_delta": task_delta, "baseline_process_leaders": baseline["process_leader_count"], "active_process_leaders": active["process_leader_count"], "leader_delta": leader_delta, "a_thread_count": trust["thread_count"], "a_worker_threads": workers}, indent=2) + "\n")
raise SystemExit(0 if ok else 1)
PY
contested=$(phase_dir b_with_a)
run_b "$B_WORKERS" "$contested/compatibility-report.json" > "$contested/stdout.txt" 2> "$contested/stderr.txt"; contested_rc=$?
[ "$contested_rc" -eq 75 ] || fail "b_with_a_unexpected_rc_$contested_rc"
[ ! -e "$contested/compatibility-report.json" ] || fail "b_with_a_wrote_report"
[ -s "$contested/descriptor-audit-attempt.json" ] || fail "b_with_a_attempt_missing"
snapshot after_contested_b
control=$(phase_dir single_process_control)
run_b 1 "$control/compatibility-report.json" > "$control/stdout.txt" 2> "$control/stderr.txt"; control_rc=$?
[ "$control_rc" -eq 0 ] || fail "single_process_control_rc_$control_rc"
B_OUTPUT_OVERRIDE="$control/compatibility-report.json" EXPECTED_B_WORKERS=1 bash "$CASE_PRIVATE_ROOT/eval/task_check_b.sh" > "$evidence/single_process_control_grade.txt" 2>&1 || fail "single_process_control_contract"
snapshot after_single_process_control
bash "$CASE_PRIVATE_ROOT/a/status_a.sh" > "$evidence/status_a_after_b.txt" 2>&1 || fail "a_unhealthy_after_b"
bash "$CASE_PRIVATE_ROOT/eval/peer_check_a.sh" > "$evidence/peer_a_after_b.txt" 2>&1 || fail "a_identity_or_progress"
bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" > "$evidence/stop_a.txt" 2>&1 || fail "a_normal_stop"
started=0
snapshot after_a_release
recovery=$(phase_dir b_recovery)
run_b "$B_WORKERS" "$recovery/compatibility-report.json" > "$recovery/stdout.txt" 2> "$recovery/stderr.txt"; recovery_rc=$?
[ "$recovery_rc" -eq 0 ] || fail "b_recovery_rc_$recovery_rc"
B_OUTPUT_OVERRIDE="$recovery/compatibility-report.json" bash "$CASE_PRIVATE_ROOT/eval/task_check_b.sh" > "$evidence/b_recovery_grade.txt" 2>&1 || fail "b_recovery_contract"
snapshot final
python3 - "$evidence/with_a_before_b.json" "$evidence/after_contested_b.json" "$evidence/after_single_process_control.json" "$contested/descriptor-audit-attempt.json" "$evidence/a_process_limits.txt" "$evidence/thread_accounting.json" "$CGROUP_LIMIT" "$B_WORKERS" "$evidence/final_assertions.json" <<'PY' || fail "final_assertions"
import json, pathlib, re, sys
before = json.load(open(sys.argv[1])); after = json.load(open(sys.argv[2])); control = json.load(open(sys.argv[3])); attempt = json.load(open(sys.argv[4])); limits = pathlib.Path(sys.argv[5]).read_text(); accounting = json.load(open(sys.argv[6])); cgroup_limit, required_workers = map(int, sys.argv[7:9])
match = re.search(r"^Max processes\s+(\S+)\s+(\S+)", limits, re.MULTILINE)
if not match: raise SystemExit("RLIMIT_NPROC row missing")
soft = match.group(1); nproc_headroom = soft == "unlimited" or int(soft) >= cgroup_limit + required_workers
before_max = int(before.get("pids_events", {}).get("max", 0)); after_max = int(after.get("pids_events", {}).get("max", 0))
mb, ma = before.get("memory_events", {}), after.get("memory_events", {}); no_oom = all(int(ma.get(key, 0)) == int(mb.get(key, 0)) for key in ("oom", "oom_kill"))
mc, mm = before.get("memory_current"), before.get("memory_max"); memory_headroom = mm == "max" or (isinstance(mc, int) and isinstance(mm, int) and mc * 100 < mm * 80)
cpu_advanced = int(control.get("cpu_stat", {}).get("usage_usec", 0)) > int(before.get("cpu_stat", {}).get("usage_usec", 0))
ok = (accounting.get("ok") is True and before.get("pids_max") == str(cgroup_limit) and after.get("pids_max") == str(cgroup_limit) and after_max > before_max and attempt.get("complete") is False and attempt.get("required_workers") == required_workers and 0 < attempt.get("launched_workers", required_workers) < required_workers and attempt.get("errno") == 11 and nproc_headroom and no_oom and memory_headroom and cpu_advanced)
pathlib.Path(sys.argv[9]).write_text(json.dumps({"ok": ok, "pids_max": cgroup_limit, "pids_event_before": before_max, "pids_event_after": after_max, "pids_event_delta": after_max - before_max, "spawn_errno": attempt.get("errno"), "launched_workers": attempt.get("launched_workers"), "required_workers": required_workers, "rlimit_nproc_soft": soft, "rlimit_nproc_nonbinding": nproc_headroom, "memory_current": mc, "memory_max": mm, "memory_headroom": memory_headroom, "oom_counters_unchanged": no_oom, "cpu_max": before.get("cpu_max"), "cpu_work_advanced": cpu_advanced, "thread_accounting": accounting}, indent=2) + "\n")
raise SystemExit(0 if ok else 1)
PY
archive_phases || fail "phase_archive"
echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 PID_EVENTS=1 THREAD_ACCOUNTING=1 ALT_LIMITS_EXCLUDED=1 B_RECOVERY_OK=1 RESOURCE=process_slots REASON=cgroup_native_threads_count_as_tasks"
trap - EXIT INT TERM
exit 0
