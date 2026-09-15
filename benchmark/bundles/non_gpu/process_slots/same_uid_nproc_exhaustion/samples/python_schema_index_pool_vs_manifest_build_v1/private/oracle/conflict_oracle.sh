#!/bin/bash
set -Eeuo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/case-secret/case}
. "$ROOT/fixture.env"
mkdir -p "$RESULT_ROOT/evidence/phases"
chmod 700 "$RESULT_ROOT" "$RESULT_ROOT/evidence" "$RESULT_ROOT/evidence/phases"
step=initialization
passed=0
cleanup() {
  if [ "$passed" -ne 1 ]; then
    bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
  fi
}
on_error() {
  local rc=$?
  trap - ERR
  echo "CONFLICT_OK=0 RESOURCE=process_slots REASON=same_uid_nproc_exhaustion_failed step=$step rc=$rc"
  exit "$rc"
}
trap cleanup EXIT
trap on_error ERR
prepare_output() {
  local path=$1 uid=$2 gid=$3
  rm -rf "$path"
  install -d -o "$uid" -g "$gid" -m 700 "$path"
}
run_graph() {
  local uid=$1 gid=$2 source=$3 output=$4 limit=$5 workers=$6
  local name
  name=$(getent passwd "$uid" | cut -d: -f1)
  prlimit --nproc="$limit:$limit" -- \
    setpriv --reuid="$uid" --regid="$gid" --init-groups \
    env -i HOME="/home/$name" USER="$name" LOGNAME="$name" PATH="$FIXED_PATH" \
    python3 "$B_TOOL" --source "$source" --output "$output" --workers "$workers" --owner-uid "$uid" --limit "$limit"
}
check_success() {
  local output=$1 uid=$2 workers=$3 modules=$4
  python3 - "$output" "$uid" "$workers" "$modules" "$NPROC_LIMIT" <<'PY'
import json
import pathlib
import sys
output, uid, workers, modules, limit = sys.argv[1:]
root = pathlib.Path(output)
uid, workers, modules, limit = map(int, (uid, workers, modules, limit))
attempt = json.loads((root / "attempt.json").read_text())
summary = json.loads((root / "build-summary.json").read_text())
manifest = json.loads((root / "dependency-manifest.json").read_text())
assert attempt["complete"] is True
assert attempt["uid"] == uid and attempt["rlimit_nproc"] == [limit, limit]
assert attempt["launched_workers"] == workers and attempt["required_workers"] == workers
assert summary["complete"] is True and summary["worker_count"] == workers
assert summary["module_count"] == modules and summary["owner_uid"] == uid
assert manifest["complete"] is True and manifest["module_count"] == modules
assert len(list(root.glob("worker-*.json"))) == workers
assert all(path.stat().st_uid == uid for path in [root, *root.rglob("*")])
PY
}
copy_phase() {
  local source=$1 name=$2
  rm -rf "$RESULT_ROOT/evidence/phases/$name"
  cp -a "$source" "$RESULT_ROOT/evidence/phases/$name"
}
step=initial_uid_and_cgroup_inventory
python3 "$ROOT/data/account_inventory.py" "$SERVICE_UID" --require-count 0 > "$RESULT_ROOT/evidence/service_uid_initial.json"
python3 "$ROOT/data/account_inventory.py" "$CONTROL_UID" --require-count 0 > "$RESULT_ROOT/evidence/control_uid_initial.json"
python3 "$ROOT/data/pid_capacity.py" --min-headroom "$MIN_CGROUP_HEADROOM" --output "$RESULT_ROOT/evidence/cgroup_initial.json"
step=b_alone
alone_output=/work/out/checks/alone
prepare_output "$alone_output" "$SERVICE_UID" "$SERVICE_GID"
run_graph "$SERVICE_UID" "$SERVICE_GID" "$B_SOURCE_ROOT" "$alone_output" "$NPROC_LIMIT" "$B_WORKERS" > "$RESULT_ROOT/evidence/b_alone.stdout" 2> "$RESULT_ROOT/evidence/b_alone.stderr"
check_success "$alone_output" "$SERVICE_UID" "$B_WORKERS" "$B_MODULES"
copy_phase "$alone_output" b_alone
python3 "$ROOT/data/account_inventory.py" "$SERVICE_UID" --require-count 0 > "$RESULT_ROOT/evidence/service_uid_after_alone.json"
step=start_and_capture_a
bash "$ROOT/a/start_a.sh" > "$RESULT_ROOT/evidence/start_a.txt" 2>&1
bash "$ROOT/a/status_a.sh" > "$RESULT_ROOT/evidence/status_a.txt" 2>&1
bash "$ROOT/eval/capture_a_trust.sh" > "$RESULT_ROOT/evidence/capture_a_trust.txt" 2>&1
python3 "$ROOT/data/pid_capacity.py" --min-headroom "$MIN_CGROUP_HEADROOM" --output "$RESULT_ROOT/evidence/cgroup_with_a_before_b.json"
step=same_uid_contested_b
contested_output=/work/out/checks/contested
prepare_output "$contested_output" "$SERVICE_UID" "$SERVICE_GID"
trap - ERR
set +e
run_graph "$SERVICE_UID" "$SERVICE_GID" "$B_SOURCE_ROOT" "$contested_output" "$NPROC_LIMIT" "$B_WORKERS" > "$RESULT_ROOT/evidence/b_with_a.stdout" 2> "$RESULT_ROOT/evidence/b_with_a.stderr"
contested_rc=$?
set -e
trap on_error ERR
[ "$contested_rc" -eq 75 ]
copy_phase "$contested_output" b_with_a
python3 - "$contested_output/attempt.json" "$SERVICE_UID" "$NPROC_LIMIT" "$A_WORKERS" "$B_WORKERS" > "$RESULT_ROOT/evidence/contested_check.txt" <<'PY'
import errno
import json
import pathlib
import sys
path, uid, limit, a_workers, b_workers = sys.argv[1:]
uid, limit, a_workers, b_workers = map(int, (uid, limit, a_workers, b_workers))
attempt = json.loads(pathlib.Path(path).read_text())
expected_a_tasks = a_workers + 1
expected_launched = limit - expected_a_tasks - 1
checks = {
    "complete_false": attempt.get("complete") is False,
    "uid": attempt.get("uid") == uid,
    "limit": attempt.get("rlimit_nproc") == [limit, limit],
    "eagain": attempt.get("spawn_errno") == errno.EAGAIN,
    "required_workers": attempt.get("required_workers") == b_workers,
    "launched_expected": attempt.get("launched_workers") == expected_launched,
    "launched_short": attempt.get("launched_workers", b_workers) < b_workers,
    "uid_count_at_limit": attempt.get("uid_task_count_at_cohort") == limit,
    "inventory_at_limit": len(attempt.get("uid_task_inventory_at_cohort", [])) == limit,
    "limits_inherited": all(task.get("rlimit_nproc") == {"soft": str(limit), "hard": str(limit)} for task in attempt.get("uid_task_inventory_at_cohort", [])),
}
print(json.dumps({"checks": checks, "summary": {key: attempt.get(key) for key in ("complete", "uid", "rlimit_nproc", "spawn_errno", "required_workers", "launched_workers", "uid_task_count_at_cohort")}}, indent=2))
assert all(checks.values())
PY
python3 "$ROOT/data/account_inventory.py" "$SERVICE_UID" --require-count "$((A_WORKERS + 1))" > "$RESULT_ROOT/evidence/service_uid_after_contested.json"
python3 "$ROOT/data/pid_capacity.py" --min-headroom "$MIN_CGROUP_HEADROOM" --output "$RESULT_ROOT/evidence/cgroup_after_contested.json"
python3 - "$RESULT_ROOT/evidence/cgroup_with_a_before_b.json" "$RESULT_ROOT/evidence/cgroup_after_contested.json" <<'PY'
import json
import sys
before, after = (json.load(open(path)) for path in sys.argv[1:])
assert before["headroom_ok"] is True and after["headroom_ok"] is True
assert before["minimum_finite_headroom"] is None or before["minimum_finite_headroom"] >= before["required_headroom"]
assert after["minimum_finite_headroom"] is None or after["minimum_finite_headroom"] >= after["required_headroom"]
PY
bash "$ROOT/eval/peer_check_a.sh" > "$RESULT_ROOT/evidence/peer_after_contested.txt" 2>&1
grep -q '^PEER_OK=1 ' "$RESULT_ROOT/evidence/peer_after_contested.txt"
step=different_uid_diagnostic_control
control_root=/run/schema-index-control
rm -rf "$control_root"
install -d -o "$CONTROL_UID" -g "$CONTROL_GID" -m 700 "$control_root" "$control_root/repo" "$control_root/out"
cp -a "$B_SOURCE_ROOT/." "$control_root/repo/"
chown -R "$CONTROL_UID:$CONTROL_GID" "$control_root/repo"
run_graph "$CONTROL_UID" "$CONTROL_GID" "$control_root/repo" "$control_root/out" "$NPROC_LIMIT" "$B_WORKERS" > "$RESULT_ROOT/evidence/different_uid.stdout" 2> "$RESULT_ROOT/evidence/different_uid.stderr"
check_success "$control_root/out" "$CONTROL_UID" "$B_WORKERS" "$B_MODULES"
copy_phase "$control_root/out" different_uid_control
python3 "$ROOT/data/account_inventory.py" "$CONTROL_UID" --require-count 0 > "$RESULT_ROOT/evidence/control_uid_after.json"
step=root_exemption_control
root_root="$RESULT_ROOT/evidence/root_manifest"
prepare_output "$root_root" 0 0
prlimit --nproc=1:1 -- python3 "$B_TOOL" --source "$B_SOURCE_ROOT" --output "$root_root" --workers 3 --owner-uid 0 --limit 1 > "$RESULT_ROOT/evidence/root_control.stdout" 2> "$RESULT_ROOT/evidence/root_control.stderr"
python3 - "$root_root" <<'PY'
import json
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
attempt = json.loads((root / "attempt.json").read_text())
summary = json.loads((root / "build-summary.json").read_text())
assert attempt["uid"] == 0 and attempt["rlimit_nproc"] == [1, 1]
assert attempt["complete"] is True and attempt["launched_workers"] == 3
assert summary["complete"] is True and summary["owner_uid"] == 0
PY
bash "$ROOT/eval/peer_check_a.sh" > "$RESULT_ROOT/evidence/peer_after_controls.txt" 2>&1
grep -q '^PEER_OK=1 ' "$RESULT_ROOT/evidence/peer_after_controls.txt"
step=normal_a_release
bash "$ROOT/a/stop_a.sh" > "$RESULT_ROOT/evidence/stop_a.txt" 2>&1
grep -q '^A_STOPPED=1 mode=graceful ' "$RESULT_ROOT/evidence/stop_a.txt"
python3 "$ROOT/data/account_inventory.py" "$SERVICE_UID" --require-count 0 > "$RESULT_ROOT/evidence/service_uid_after_release.json"
cp -a "$A_RUNTIME_ROOT/service.log" "$RESULT_ROOT/evidence/a_service.log"
step=unchanged_b_recovery
prepare_output "$B_OUTPUT_ROOT" "$SERVICE_UID" "$SERVICE_GID"
run_graph "$SERVICE_UID" "$SERVICE_GID" "$B_SOURCE_ROOT" "$B_OUTPUT_ROOT" "$NPROC_LIMIT" "$B_WORKERS" > "$RESULT_ROOT/evidence/b_after_release.stdout" 2> "$RESULT_ROOT/evidence/b_after_release.stderr"
check_success "$B_OUTPUT_ROOT" "$SERVICE_UID" "$B_WORKERS" "$B_MODULES"
copy_phase "$B_OUTPUT_ROOT" b_after_release
python3 "$ROOT/data/account_inventory.py" "$SERVICE_UID" --require-count 0 > "$RESULT_ROOT/evidence/service_uid_final.json"
python3 "$ROOT/data/pid_capacity.py" --min-headroom "$MIN_CGROUP_HEADROOM" --output "$RESULT_ROOT/evidence/cgroup_final.json"
passed=1
trap - ERR
echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 SAME_UID_EAGAIN=1 UID_COUNT_AT_FAILURE=$NPROC_LIMIT RLIMIT_INHERITED=1 CGROUP_HEADROOM=1 ROOT_EXEMPTION=1 DIFFERENT_UID_CONTROL=1 A_IDENTITY_RETAINED=1 A_PROGRESS=1 NORMAL_RELEASE=1 B_RECOVERY_OK=1 RESOURCE=process_slots REASON=same_uid_nproc_exhaustion"
