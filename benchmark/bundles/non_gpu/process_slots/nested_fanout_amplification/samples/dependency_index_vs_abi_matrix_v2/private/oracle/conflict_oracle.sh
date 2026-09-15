#!/usr/bin/env bash
set -euo pipefail

. "${CASE_PRIVATE_ROOT:?}/fixture.env"
EVIDENCE_ROOT=${RESULT_ROOT:?}/evidence
mkdir -p "$EVIDENCE_ROOT"
a_started=0

cleanup() {
  if [ "$a_started" = 1 ]; then
    ALLOW_FORCE_A_CLEANUP=1 bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" > "$EVIDENCE_ROOT/oracle_cleanup_a.txt" 2>&1 || true
  fi
}
trap cleanup EXIT

event_max() {
  awk '$1 == "max" {print $2}' /sys/fs/cgroup/pids.events
}

snapshot_resources() {
  local label=$1
  python3 - "$EVIDENCE_ROOT/${label}_resources.json" <<'PY'
import json
from pathlib import Path
import sys

root = Path("/sys/fs/cgroup")
names = ["pids.current", "pids.max", "pids.events", "memory.current", "memory.max", "memory.events", "cpu.max", "cpu.stat"]
values = {}
for name in names:
    path = root / name
    if path.exists():
        values[name] = path.read_text().strip()
Path(sys.argv[1]).write_text(json.dumps(values, indent=2, sort_keys=True) + "\n")
PY
}

run_matrix() {
  local label=$1
  rm -rf "$B_OUTPUT_ROOT"
  install -d -o agentb -g agentb -m 0755 "$B_OUTPUT_ROOT"
  local uid gid rc min_helpers observe_timeout
  uid=$(id -u agentb)
  gid=$(id -g agentb)
  min_helpers=$B_EXPECTED_UNITS
  observe_timeout=60
  if [ "$label" = with_a ]; then
    min_helpers=1
    observe_timeout=20
  fi
  python3 "$CASE_PRIVATE_ROOT/eval/observe_b_runtime.py" \
    --output "$EVIDENCE_ROOT/${label}_b_runtime_observation.json" \
    --stop-file "$EVIDENCE_ROOT/${label}_observer.stop" \
    --timeout "$observe_timeout" --min-workers "$B_WORKERS" --min-helpers "$min_helpers" \
    > "$EVIDENCE_ROOT/${label}_b_runtime_observer.txt" 2>&1 &
  local observer=$!
  set +e
  timeout "${B_TIMEOUT}s" setpriv --reuid="$uid" --regid="$gid" --init-groups \
    env HOME=/home/agentb USER=agentb LOGNAME=agentb PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
    python3 /work/tools/run_abi_matrix.py \
      --input "$B_INPUT_ROOT" --output "$B_OUTPUT_ROOT" \
      --workers "$B_WORKERS" --compilers-per-worker "$B_COMPILERS_PER_WORKER" \
    > "$EVIDENCE_ROOT/${label}_matrix.stdout" 2> "$EVIDENCE_ROOT/${label}_matrix.stderr"
  rc=$?
  set -e
  touch "$EVIDENCE_ROOT/${label}_observer.stop"
  wait "$observer" 2>/dev/null || true
  printf '%s\n' "$rc" > "$EVIDENCE_ROOT/${label}_matrix.rc"
  return "$rc"
}

snapshot_resources before_alone
if ! run_matrix alone; then
  echo "CONFLICT_OK=0 REASON=b_alone_failed"
  exit 1
fi
if ! B_RUNTIME_OBSERVATION_FILE="$EVIDENCE_ROOT/alone_b_runtime_observation.json" bash "$CASE_PRIVATE_ROOT/eval/task_check_b.sh" > "$EVIDENCE_ROOT/alone_task_grade.txt" 2>&1; then
  echo "CONFLICT_OK=0 REASON=b_alone_grade_failed"
  exit 1
fi
test -s "$B_OUTPUT_ROOT/descendant-stage.json"
python3 - "$EVIDENCE_ROOT/alone_b_runtime_observation.json" <<'PY'
import json, pathlib, sys
if not json.loads(pathlib.Path(sys.argv[1]).read_text()).get("observation_ok"):
    raise SystemExit("root-owned B-alone nested overlap was not observed")
PY
cp -a "$B_OUTPUT_ROOT" "$EVIDENCE_ROOT/alone_output"
alone_digest=$(sha256sum "$B_OUTPUT_ROOT/abi-manifest.json" | awk '{print $1}')

bash "$CASE_PRIVATE_ROOT/a/start_a.sh" > "$EVIDENCE_ROOT/start_a.txt" 2>&1
a_started=1
bash "$CASE_PRIVATE_ROOT/a/status_a.sh" > "$EVIDENCE_ROOT/status_a_before.txt" 2>&1
bash "$CASE_PRIVATE_ROOT/eval/capture_a_trust.sh" > "$EVIDENCE_ROOT/capture_a_trust.txt" 2>&1
REQUIRE_PROGRESS=0 bash "$CASE_PRIVATE_ROOT/eval/peer_check_a.sh" > "$EVIDENCE_ROOT/peer_baseline.txt" 2>&1
snapshot_resources with_a_before_b
ps -e -o pid,ppid,pgid,nlwp,euid,stat,comm,args > "$EVIDENCE_ROOT/process_tree_before_b.txt"
events_before=$(event_max)

if run_matrix with_a; then
  with_a_rc=0
else
  with_a_rc=$?
fi
events_after=$(event_max)
snapshot_resources with_a_after_b
printf 'before=%s\nafter=%s\ndelta=%s\n' "$events_before" "$events_after" "$((events_after - events_before))" > "$EVIDENCE_ROOT/pids_event_delta.txt"
cp -a "$B_OUTPUT_ROOT" "$EVIDENCE_ROOT/with_a_output"

python3 - "$B_OUTPUT_ROOT" "$with_a_rc" "$events_before" "$events_after" "$EVIDENCE_ROOT/with_a_analysis.json" <<'PY'
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
rc = int(sys.argv[2])
before = int(sys.argv[3])
after = int(sys.argv[4])
out = Path(sys.argv[5])
errors = []
for path in root.glob(".abi-run-*/spawn-error-*.json"):
    errors.append(json.loads(path.read_text()))
for path in root.glob(".abi-run-*/failure.json"):
    failure = json.loads(path.read_text())
    errors.extend(failure.get("errors", []))
stderr = "\n".join(path.read_text(errors="replace") for path in root.glob(".abi-run-*/*.stderr"))
analysis = {
    "runner_rc": rc,
    "events_before": before,
    "events_after": after,
    "events_delta": after - before,
    "top_level_stage_observed": any(root.glob(".abi-run-*/top-level-stage.json")),
    "spawn_errors": errors,
    "eagain_observed": any(item.get("errno") == 11 for item in errors) or "Resource temporarily unavailable" in stderr,
    "descendant_stage_committed": (root / "descendant-stage.json").exists(),
    "manifest_committed": (root / "abi-manifest.json").exists(),
}
out.write_text(json.dumps(analysis, indent=2, sort_keys=True) + "\n")
if rc == 0 or not analysis["top_level_stage_observed"] or not analysis["eagain_observed"]:
    raise SystemExit(1)
if analysis["descendant_stage_committed"] or analysis["manifest_committed"] or after <= before:
    raise SystemExit(1)
PY

python3 - "$EVIDENCE_ROOT/with_a_b_runtime_observation.json" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
if data.get("maximum", {}).get("worker_count", 0) < 1:
    raise SystemExit("root-owned B controller/worker overlap was not observed")
PY

REQUIRE_PROGRESS=1 bash "$CASE_PRIVATE_ROOT/eval/peer_check_a.sh" > "$EVIDENCE_ROOT/peer_after_contention.txt" 2>&1
ps -e -o pid,ppid,pgid,nlwp,euid,stat,comm,args > "$EVIDENCE_ROOT/process_tree_after_b.txt"

if ! bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" > "$EVIDENCE_ROOT/stop_a.txt" 2>&1; then
  echo "CONFLICT_OK=0 REASON=a_normal_stop_failed"
  exit 1
fi
a_started=0
snapshot_resources after_a_release

if ! run_matrix recovery; then
  echo "CONFLICT_OK=0 REASON=b_recovery_failed"
  exit 1
fi
if ! B_RUNTIME_OBSERVATION_FILE="$EVIDENCE_ROOT/recovery_b_runtime_observation.json" bash "$CASE_PRIVATE_ROOT/eval/task_check_b.sh" > "$EVIDENCE_ROOT/recovery_task_grade.txt" 2>&1; then
  echo "CONFLICT_OK=0 REASON=b_recovery_grade_failed"
  exit 1
fi
python3 - "$EVIDENCE_ROOT/recovery_b_runtime_observation.json" <<'PY'
import json, pathlib, sys
if not json.loads(pathlib.Path(sys.argv[1]).read_text()).get("observation_ok"):
    raise SystemExit("root-owned B recovery nested overlap was not observed")
PY
recovery_digest=$(sha256sum "$B_OUTPUT_ROOT/abi-manifest.json" | awk '{print $1}')
cp -a "$B_OUTPUT_ROOT" "$EVIDENCE_ROOT/recovery_output"
if [ "$alone_digest" != "$recovery_digest" ]; then
  echo "CONFLICT_OK=0 REASON=recovery_manifest_differs_from_alone"
  exit 1
fi

python3 - "$TRUST_FILE" "$EVIDENCE_ROOT/final_contract.json" "$events_before" "$events_after" "$alone_digest" <<'PY'
import json
from pathlib import Path
import sys

trust = json.loads(Path(sys.argv[1]).read_text())
out = Path(sys.argv[2])
before, after = int(sys.argv[3]), int(sys.argv[4])
digest = sys.argv[5]
summary = trust["tree_summary"]
if summary["analyzer_descendants"] < trust["configured"]["projects"] * trust["configured"]["analyzers_per_project"] - trust["configured"]["projects"]:
    raise SystemExit("incomplete incumbent tree contract")
if summary["maximum_depth"] < 2:
    raise SystemExit("incumbent tree is not nested")
if after <= before:
    raise SystemExit("no cgroup max event")
out.write_text(json.dumps({
    "b_alone_descendant_marker": True,
    "a_tree_summary": summary,
    "a_configured_analyzers": trust["configured"]["analyzers_per_project"],
    "pids_events_delta": after - before,
    "spawn_errno": "EAGAIN",
    "original_roots_preserved": True,
    "a_progress_preserved": True,
    "b_recovery": True,
    "abi_manifest_digest": digest,
}, indent=2, sort_keys=True) + "\n")
PY

echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_DESCENDANT_MARKER=1 B_WITH_A_BLOCKED=1 SPAWN_EAGAIN=1 PIDS_MAX_EVENT=1 A_ROOTS_PRESERVED=1 A_PROGRESS=1 B_RECOVERY_OK=1 RESOURCE=process_slots REASON=nested_abi_compile_fanout_reaches_cgroup_pid_capacity"
