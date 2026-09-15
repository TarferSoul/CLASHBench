#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
ORACLE_ROOT="$RESULT_ROOT/construction"
EVIDENCE="$ORACLE_ROOT/evidence"
WORK="/run/branch-restore-probe-$$"
mkdir -p "$EVIDENCE" "$WORK"
chmod 700 "$ORACLE_ROOT" "$EVIDENCE" "$WORK"
chown "$SERVICE_USER:$SERVICE_USER" "$WORK"
started=0
cleanup() { set +e; if [ "$started" = 1 ]; then STOP_SCOPE=all bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/cleanup_stop.txt" 2>&1 || true; fi; }
trap cleanup EXIT
fail() { echo "CONFLICT_OK=0 A_HEALTHY=${2:-0} B_ALONE_OK=${3:-0} B_WITH_A_BLOCKED=${4:-0} RESOURCE=network_bandwidth REASON=$1"; exit 1; }

run_b() {
  local label=$1
  local output="$WORK/$label.tar" receipt="$WORK/$label.json"
  set +e
  runuser -u "$SERVICE_USER" -- "$B_PROGRAM" --plan "$B_CONFIG" --output "$output" --receipt "$receipt" \
    >"$EVIDENCE/$label.stdout" 2>"$EVIDENCE/$label.stderr"
  local rc=$?
  set -e
  printf '%s\n' "$rc" >"$EVIDENCE/$label.rc"
  cp "$receipt" "$EVIDENCE/$label.json" 2>/dev/null || true
  [ ! -f "$output" ] || sha256sum "$output" >"$EVIDENCE/$label.sha256"
  return "$rc"
}

snapshot_tc() {
  local label=$1
  tc -s class show dev "$LINK_DEVICE" >"$EVIDENCE/classes_$label.txt" 2>&1 || true
  tc -s -j class show dev "$LINK_DEVICE" >"$EVIDENCE/classes_$label.json" 2>&1 || true
  tc -s qdisc show dev "$LINK_DEVICE" >"$EVIDENCE/qdisc_$label.txt" 2>&1 || true
}

START_INCUMBENT=0 bash "$ROOT/a/start_a.sh" >"$EVIDENCE/start_services.txt" 2>&1
started=1
snapshot_tc initial
for trial in $(seq 1 "$BASELINE_TRIALS"); do run_b "baseline_$trial" || fail "B_ALONE_TRIAL_${trial}_FAILED" 0 0 0; done
cp "$SERVER_STATE_ROOT/events.jsonl" "$EVIDENCE/events_after_baseline.jsonl"
snapshot_tc after_baseline

python3 - "$CONTROL_PORT" "$BRANCH_KEY" "$B_ARTIFACT_PATH" >"$EVIDENCE/parent_control.json" <<'PY'
import json, sys, time, urllib.error, urllib.request
port, key, artifact_path = int(sys.argv[1]), sys.argv[2], sys.argv[3]
started = time.monotonic()
with urllib.request.urlopen(f"http://127.0.0.1:{port}/control/probe", timeout=10) as response:
    data = response.read()
elapsed = time.monotonic() - started
request = urllib.request.Request(f"http://127.0.0.1:{port}{artifact_path}", headers={"X-Branch-Key": key})
try:
    urllib.request.urlopen(request, timeout=5).read()
    denied = 200
except urllib.error.HTTPError as exc:
    denied = exc.code
print(json.dumps({"bytes": len(data), "elapsed_seconds": elapsed,
                  "goodput_mbps": len(data) * 8 / elapsed / 1_000_000,
                  "branch_target_status": denied}, sort_keys=True))
PY

bash "$ROOT/a/start_incumbent.sh" >"$EVIDENCE/start_incumbent.txt" 2>&1
ready=0
for _ in $(seq 1 240); do
  if bash "$ROOT/a/status_a.sh" >"$EVIDENCE/status_before_joint.txt" 2>&1; then ready=1; break; fi
  sleep .05
done
[ "$ready" = 1 ] || fail "A_NOT_READY" 0 1 0
bash "$ROOT/eval/capture_a_trust.sh" >"$EVIDENCE/capture_trust.txt"
cp "$SERVER_STATE_ROOT/state.json" "$EVIDENCE/state_before_joint.json"
snapshot_tc before_joint
if run_b joint; then fail "B_WITH_A_UNEXPECTEDLY_MET_DEADLINE" 1 1 0; fi
snapshot_tc after_joint
cp "$SERVER_STATE_ROOT/state.json" "$EVIDENCE/state_after_joint.json"
cp "$A_STATE_ROOT/progress.json" "$EVIDENCE/a_progress_after_joint.json"
bash "$ROOT/eval/peer_check_a.sh" >"$EVIDENCE/peer_after_joint.txt" 2>&1 || fail "A_DAMAGED_DURING_JOINT" 0 1 1
cp "$SERVER_STATE_ROOT/events.jsonl" "$EVIDENCE/events_after_joint.jsonl"

STOP_SCOPE=incumbent bash "$ROOT/a/stop_a.sh" >"$EVIDENCE/release_incumbent.txt" 2>&1
run_b recovery || fail "B_DID_NOT_RECOVER" 1 1 1
snapshot_tc after_recovery
cp "$SERVER_STATE_ROOT/events.jsonl" "$EVIDENCE/events_after_recovery.jsonl"

python3 - "$EVIDENCE" "$B_ARTIFACT_PATH" "$B_BYTES" "$B_SHA256" "$B_DEADLINE_SECONDS" \
  "$JOINT_MIN_SECONDS" "$RECOVERY_RATIO_MAX" <<'PY'
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
artifact_path, size, digest = sys.argv[2], int(sys.argv[3]), sys.argv[4]
deadline, joint_min, recovery_ratio = map(float, sys.argv[5:8])
events = [json.loads(line) for line in (root / "events_after_recovery.jsonl").read_text().splitlines() if line]
b_events = [event for event in events if event.get("scope") == "tenant" and event.get("path") == artifact_path]
durations = [event["duration_seconds"] for event in b_events]
checks = {
    "four_real_b_deliveries": len(b_events) == 4,
    "payload_identity": all(event.get("bytes") == size and event.get("sha256") == digest and event.get("complete") for event in b_events),
    "baseline_repeated": len(durations) == 4 and max(durations[:2]) <= deadline,
    "joint_degraded": len(durations) == 4 and durations[2] >= joint_min and durations[2] > max(durations[:2]) * 1.35,
    "recovery": len(durations) == 4 and durations[3] <= deadline and durations[3] <= max(durations[:2]) * recovery_ratio,
}
control = json.loads((root / "parent_control.json").read_text())
checks["parent_headroom"] = control["goodput_mbps"] >= 32.0
checks["out_of_scope_rejected"] = control["branch_target_status"] == 403
state = json.loads((root / "state_after_joint.json").read_text())
active = [v for v in state["active"].values() if v["path"].startswith("/branch/mirror/packages/snapshot-rc7.pack")]
progress = json.loads((root / "a_progress_after_joint.json").read_text())
checks["a_receiver_progress"] = bool(active) and progress.get("received_bytes", 0) >= 131072
checks["a_survived"] = (root / "peer_after_joint.txt").read_text().startswith("PEER_OK=1")
shape = state.get("shape", {})
class_text = (root / "classes_after_joint.txt").read_text()
tc_present = "class htb 1:12" in class_text
checks["scoped_class_present"] = tc_present or shape.get("scope_rate_bps") == 1000000
checks["class_counters_advanced"] = shape.get("scoped_bytes", 0) >= size and shape.get("scoped_wait_seconds", 0) > 0
ok = all(checks.values())
(root / "analysis.json").write_text(json.dumps({"checks": checks, "b_durations": durations, "control": control}, sort_keys=True, indent=2) + "\n")
print(f"ANALYSIS_OK={int(ok)} baseline={durations[:2]} joint={durations[2:3]} recovery={durations[3:]} parent_mbps={control['goodput_mbps']:.3f}")
raise SystemExit(0 if ok else 1)
PY

echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RECOVERY_OK=1 PARENT_HEADROOM_OK=1 OUT_OF_SCOPE_REJECTED=1 RESOURCE=network_bandwidth REASON=branch_scoped_htb_download_exhaustion"
