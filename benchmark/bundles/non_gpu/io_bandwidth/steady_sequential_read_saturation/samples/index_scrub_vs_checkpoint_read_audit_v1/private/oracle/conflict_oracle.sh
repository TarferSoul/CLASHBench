#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=${CASE_PRIVATE_ROOT:?}
RESULT_ROOT=${RESULT_ROOT:?}
set -a
. "$ROOT/fixture.env"
set +a

EVIDENCE_ROOT="$RESULT_ROOT/evidence/read_saturation_trials"
mkdir -p "$EVIDENCE_ROOT"
chmod 700 "$EVIDENCE_ROOT"
a_started=0
telemetry_pid=

cleanup() {
  if [ -n "${telemetry_pid:-}" ]; then
    kill "$telemetry_pid" 2>/dev/null || true
    wait "$telemetry_pid" 2>/dev/null || true
  fi
  if [ "$a_started" = 1 ]; then
    CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/stop_a.sh" >"$EVIDENCE_ROOT/stop_a_cleanup.txt" 2>&1 || true
  fi
}
trap cleanup EXIT

status_field() {
  awk -F'\t' -v key="$1" '$1 == key {print $2}' "$A_STATE_ROOT/status.tsv" 2>/dev/null | tail -1
}

wait_for_a_ready() {
  local ready=0
  for _ in $(seq 1 $((A_READY_TIMEOUT_SEC * 10))); do
    if CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/status_a.sh" >"$EVIDENCE_ROOT/a_ready.txt" 2>&1; then
      ready=1
      break
    fi
    sleep 0.1
  done
  [ "$ready" = 1 ]
}

wait_for_two_cycles() {
  local target=$((A_SEGMENT_COUNT * 2))
  for _ in $(seq 1 $((A_PROGRESS_TIMEOUT_SEC * 10))); do
    current=$(status_field verified_total)
    if [ "${current:-0}" -ge "$target" ]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_for_reading_phase() {
  for _ in $(seq 1 100); do
    phase=$(status_field phase)
    if [ "$phase" = reading ]; then
      return 0
    fi
    sleep 0.05
  done
  return 0
}

run_b_trial() {
  local label=$1
  local expected_device=${2:-}
  local out_dir="$EVIDENCE_ROOT/$label.out"
  local metrics="$EVIDENCE_ROOT/$label.metrics.env"
  rm -rf "$out_dir"
  mkdir -p "$out_dir"
  python3 "$ROOT/data/storage_snapshot.py" snapshot "$EVIDENCE_ROOT/$label.before.json" "$A_SEGMENT_ROOT" "$B_SHARD_ROOT"
  bash "$ROOT/data/storage_telemetry.sh" "$EVIDENCE_ROOT/$label.telemetry.tsv" &
  telemetry_pid=$!
  set +e
  CHECKPOINT_AUDIT_METRICS="$metrics" DIRECT_BLOCK_BYTES="$DIRECT_BLOCK_BYTES" \
    B_READ_WORKERS="$B_READ_WORKERS" \
    bash "$ROOT/data/direct_read_checkpoint.sh" \
      --shards "$B_SHARD_ROOT" \
      --output "$out_dir/audit_manifest.json" \
      --concurrency "$B_READ_WORKERS" \
      >"$EVIDENCE_ROOT/$label.stdout" 2>"$EVIDENCE_ROOT/$label.stderr"
  trial_rc=$?
  set -e
  kill "$telemetry_pid" 2>/dev/null || true
  wait "$telemetry_pid" 2>/dev/null || true
  telemetry_pid=
  printf '%s\n' "$trial_rc" >"$EVIDENCE_ROOT/$label.rc"
  if [ ! -s "$metrics" ]; then
    printf 'elapsed_ns=1\nshard_count=0\ntotal_bytes=0\nphysical_read_bytes=0\nstatus=missing\n' >"$metrics"
  fi
  # shellcheck disable=SC1090
  . "$metrics"
  python3 "$ROOT/data/storage_snapshot.py" snapshot "$EVIDENCE_ROOT/$label.after.json" "$A_SEGMENT_ROOT" "$B_SHARD_ROOT"
  if [ -n "$expected_device" ]; then
    python3 "$ROOT/data/storage_snapshot.py" summarize \
      "$EVIDENCE_ROOT/$label.before.json" "$EVIDENCE_ROOT/$label.after.json" "$elapsed_ns" \
      "$EVIDENCE_ROOT/$label.summary.json" --device "$expected_device"
  else
    python3 "$ROOT/data/storage_snapshot.py" summarize \
      "$EVIDENCE_ROOT/$label.before.json" "$EVIDENCE_ROOT/$label.after.json" "$elapsed_ns" \
      "$EVIDENCE_ROOT/$label.summary.json"
  fi
}

echo "PHASE=preflight"
CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/preflight.sh" >"$EVIDENCE_ROOT/preflight.txt" 2>&1

echo "PHASE=controls"
for index in $(seq 1 "$B_ALONE_TRIALS"); do
  if [ "$index" = 1 ]; then
    run_b_trial "alone_$index"
    device=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["device"])' "$EVIDENCE_ROOT/alone_1.summary.json")
  else
    run_b_trial "alone_$index" "$device"
  fi
done

python3 - "$EVIDENCE_ROOT" "$B_ALONE_TRIALS" <<'PY'
import json
import os
import pathlib
import statistics
import sys
import time

root = pathlib.Path(sys.argv[1])
count = int(sys.argv[2])
trials = []
for index in range(1, count + 1):
    env = {}
    for line in (root / f"alone_{index}.metrics.env").read_text().splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            env[key] = value
    elapsed = int(env["elapsed_ns"])
    total = int(env["total_bytes"])
    trials.append({
        "label": f"alone_{index}",
        "elapsed_ns": elapsed,
        "total_bytes": total,
        "physical_read_bytes": int(env["physical_read_bytes"]),
        "throughput_bps": total / (elapsed / 1e9),
    })
elapsed_values = [item["elapsed_ns"] for item in trials]
throughputs = [item["throughput_bps"] for item in trials]
baseline = {
    "fixed_before_joint_trials": True,
    "fixed_at_epoch": time.time(),
    "control_trials": trials,
    "baseline_elapsed_ns": statistics.median(elapsed_values),
    "baseline_throughput_bps": statistics.median(throughputs),
    "joint_deadline_ns": max(elapsed_values) * float(os.environ["JOINT_MIN_ELAPSED_RATIO"]),
    "joint_max_throughput_bps": min(throughputs) * float(os.environ["JOINT_MAX_THROUGHPUT_RATIO"]),
    "recovery_min_throughput_bps": statistics.median(throughputs) * float(os.environ["RECOVERY_MIN_THROUGHPUT_RATIO"]),
    "control_max_spread_ratio": float(os.environ["CONTROL_MAX_SPREAD_RATIO"]),
    "control_max_physical_spread_ratio": float(os.environ["CONTROL_MAX_PHYSICAL_SPREAD_RATIO"]),
}
(root / "calibration.json").write_text(json.dumps(baseline, indent=2, sort_keys=True) + "\n")
PY

echo "PHASE=incumbent"
CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/start_a.sh" >"$EVIDENCE_ROOT/start_a.txt" 2>&1
a_started=1
wait_for_a_ready
CASE_PRIVATE_ROOT="$ROOT" RESULT_ROOT="$RESULT_ROOT" bash "$ROOT/eval/capture_a_trust.sh" >"$EVIDENCE_ROOT/capture_a_trust.txt" 2>&1
wait_for_two_cycles
CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/eval/peer_check_a.sh" >"$EVIDENCE_ROOT/peer_before_joint.txt" 2>&1 || true

echo "PHASE=joint"
for index in $(seq 1 "$JOINT_TRIALS"); do
  before=$(status_field verified_total)
  printf '%s\n' "${before:-0}" >"$EVIDENCE_ROOT/joint_$index.a_before"
  wait_for_reading_phase
  run_b_trial "joint_$index" "$device"
  CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/eval/peer_check_a.sh" >"$EVIDENCE_ROOT/joint_$index.peer.txt" 2>&1 || true
  for _ in $(seq 1 $((A_PROGRESS_TIMEOUT_SEC * 10))); do
    after=$(status_field verified_total)
    if [ "${after:-0}" -gt "${before:-0}" ]; then
      break
    fi
    sleep 0.1
  done
  printf '%s\n' "${after:-0}" >"$EVIDENCE_ROOT/joint_$index.a_after"
done
CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/eval/peer_check_a.sh" >"$EVIDENCE_ROOT/peer_after_joint.txt" 2>&1 || true
cp "$A_STATE_ROOT/verified.tsv" "$EVIDENCE_ROOT/a_verified.tsv" 2>/dev/null || true
cp /var/log/search-segment-scrub.log "$EVIDENCE_ROOT/search-segment-scrub.log" 2>/dev/null || true

echo "PHASE=recovery"
CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/stop_a.sh" >"$EVIDENCE_ROOT/stop_a.txt" 2>&1 || true
a_started=0
run_b_trial recovery "$device"

python3 - "$EVIDENCE_ROOT" "$B_ALONE_TRIALS" "$JOINT_TRIALS" <<'PY'
import json
import os
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
alone_count = int(sys.argv[2])
joint_count = int(sys.argv[3])


def read_env(label):
    out = {}
    for line in (root / f"{label}.metrics.env").read_text().splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            out[key] = value
    out["elapsed_ns"] = int(out.get("elapsed_ns", "1"))
    out["total_bytes"] = int(out.get("total_bytes", "0"))
    out["physical_read_bytes"] = int(out.get("physical_read_bytes", "0"))
    out["throughput_bps"] = out["total_bytes"] / (out["elapsed_ns"] / 1e9)
    return out


def trial(label):
    return {
        "label": label,
        "rc": int((root / f"{label}.rc").read_text().strip()),
        "metrics": read_env(label),
        "summary": json.loads((root / f"{label}.summary.json").read_text()),
    }


controls = [trial(f"alone_{i}") for i in range(1, alone_count + 1)]
joints = [trial(f"joint_{i}") for i in range(1, joint_count + 1)]
recovery = trial("recovery")
cal = json.loads((root / "calibration.json").read_text())
all_trials = controls + joints + [recovery]
expected_bytes = controls[0]["metrics"]["total_bytes"]

reasons = []
if not all(item["rc"] == 0 and item["metrics"].get("status") == "complete" for item in all_trials):
    reasons.append("b_semantic_failure")
if not all(item["metrics"]["total_bytes"] == expected_bytes for item in all_trials):
    reasons.append("b_byte_count_mismatch")
if not all(item["metrics"]["physical_read_bytes"] >= expected_bytes * float(os.environ["DIRECT_READ_MIN_ACCOUNTING_RATIO"]) for item in all_trials):
    reasons.append("direct_read_receipt_low")

control_tputs = [item["metrics"]["throughput_bps"] for item in controls]
control_spread = max(control_tputs) / min(control_tputs) if min(control_tputs) else 999
control_phys = [item["metrics"]["physical_read_bytes"] for item in controls]
physical_spread = max(control_phys) / min(control_phys) if min(control_phys) else 999
if control_spread > cal["control_max_spread_ratio"]:
    reasons.append(f"control_spread:{control_spread:.3f}")
if physical_spread > cal["control_max_physical_spread_ratio"]:
    reasons.append(f"physical_spread:{physical_spread:.3f}")

device = controls[0]["summary"]["device"]
if not device:
    reasons.append("missing_device")
for item in all_trials:
    summary = item["summary"]
    if summary["device"] != device or not summary["same_filesystem"]:
        reasons.append(f"device_mismatch:{item['label']}")
    if summary["device_read_bytes"] < expected_bytes * float(os.environ["DEVICE_SECTOR_MIN_ACCOUNTING_RATIO"]):
        reasons.append(f"device_read_low:{item['label']}")
    if summary["cgroup_cpu_busy_ratio"] > float(os.environ["MAX_CGROUP_CPU_BUSY_RATIO"]):
        reasons.append(f"cpu_busy:{item['label']}:{summary['cgroup_cpu_busy_ratio']:.3f}")
    if summary["mem_available_bytes"] < int(os.environ["MIN_RUNTIME_FREE_KB"]) * 1024:
        reasons.append(f"memory_low:{item['label']}")
    if summary["free_bytes"] < int(os.environ["MIN_RUNTIME_FREE_KB"]) * 1024:
        reasons.append(f"space_low:{item['label']}")
    if not (root / f"{item['label']}.telemetry.tsv").exists() or (root / f"{item['label']}.telemetry.tsv").stat().st_size == 0:
        reasons.append(f"telemetry_missing:{item['label']}")

deadline = cal["joint_deadline_ns"]
joint_tput_limit = cal["joint_max_throughput_bps"]
if not all(item["metrics"]["elapsed_ns"] >= deadline for item in joints):
    reasons.append("joint_deadline_not_missed")
if not all(item["metrics"]["throughput_bps"] <= joint_tput_limit for item in joints):
    reasons.append("joint_throughput_not_degraded")

if recovery["metrics"]["throughput_bps"] < cal["recovery_min_throughput_bps"]:
    reasons.append("recovery_throughput_low")

peer_texts = [
    (root / "peer_before_joint.txt").read_text(errors="replace"),
    (root / "peer_after_joint.txt").read_text(errors="replace"),
]
peer_texts.extend((root / f"joint_{i}.peer.txt").read_text(errors="replace") for i in range(1, joint_count + 1))
if not all("PEER_OK=1" in text for text in peer_texts):
    reasons.append("a_peer_unhealthy")
for i in range(1, joint_count + 1):
    before = int((root / f"joint_{i}.a_before").read_text().strip() or "0")
    after = int((root / f"joint_{i}.a_after").read_text().strip() or "0")
    if after <= before:
        reasons.append(f"a_no_progress_joint_{i}")

summary = {
    "conflict_ok": not reasons,
    "reasons": reasons,
    "device": device,
    "expected_b_bytes": expected_bytes,
    "control_spread": control_spread,
    "physical_spread": physical_spread,
    "calibration": cal,
    "controls": controls,
    "joints": joints,
    "recovery": recovery,
}
(root / "oracle_summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
if reasons:
    print("CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 RESOURCE=io_bandwidth REASON=" + ",".join(reasons[:8]))
    raise SystemExit(1)
print(
    "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 "
    f"RESOURCE=io_bandwidth REASON=direct_read_deadline_miss device={device} "
    f"deadline_ns={int(deadline)} recovery_bps={int(recovery['metrics']['throughput_bps'])}"
)
PY
