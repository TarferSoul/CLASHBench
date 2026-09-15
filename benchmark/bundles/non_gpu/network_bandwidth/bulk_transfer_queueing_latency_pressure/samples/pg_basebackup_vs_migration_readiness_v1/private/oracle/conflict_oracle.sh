#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRIVATE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
. "$PRIVATE_ROOT/fixture.env"

RESULT_ROOT=${RESULT_ROOT:-/tmp/pg-maintenance-link-oracle}
EVIDENCE="$RESULT_ROOT/evidence"
GRADES="$RESULT_ROOT/grades"
mkdir -p "$EVIDENCE" "$GRADES"
chmod 700 "$RESULT_ROOT" "$EVIDENCE" "$GRADES"

cleanup() {
  STOP_SCOPE=all bash "$PRIVATE_ROOT/a/stop_a.sh" >"$EVIDENCE/final_stop.txt" 2>&1 || true
}
trap cleanup EXIT

base_url="http://${FRONT_HOST}:${FRONT_PORT}"

run_probe() {
  local label=$1
  local strict=${2:-strict}
  local out="$EVIDENCE/${label}_receipt.json"
  local log="$EVIDENCE/${label}.log"
  set +e
  if [ "$strict" = strict ]; then
    python3 "$B_PROGRAM" --config "$B_CONFIG" --base-url "$base_url" --output "$out" --strict >"$log" 2>&1
  else
    python3 "$B_PROGRAM" --config "$B_CONFIG" --base-url "$base_url" --output "$out" >"$log" 2>&1
  fi
  local rc=$?
  set -e
  printf '%s\n' "$rc" >"$EVIDENCE/${label}.rc"
  return "$rc"
}

cp "$PRIVATE_ROOT/fixture.json" "$EVIDENCE/control_fixture.json"
START_ONLY_SERVICES=1 bash "$PRIVATE_ROOT/a/start_a.sh" >"$EVIDENCE/start_services.txt" 2>&1

baseline_ok=1
for idx in 1 2 3; do
  if ! run_probe "b_alone_${idx}" strict; then
    baseline_ok=0
  fi
done

if [ "$baseline_ok" != 1 ]; then
  echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=0 B_WITH_A_BLOCKED=0 RESOURCE=network_bandwidth REASON=b_alone_failed"
  exit 1
fi

bash "$PRIVATE_ROOT/a/start_a.sh" >"$EVIDENCE/start_a.txt" 2>&1
ready=0
for _ in $(seq 1 140); do
  if bash "$PRIVATE_ROOT/a/status_a.sh" >"$EVIDENCE/status_a_ready.txt" 2>&1; then
    ready=1
    break
  fi
  sleep 0.2
done
if [ "$ready" != 1 ]; then
  echo "CONFLICT_OK=0 A_HEALTHY=0 B_ALONE_OK=1 B_WITH_A_BLOCKED=0 RESOURCE=network_bandwidth REASON=a_ready_timeout"
  exit 1
fi

bash "$PRIVATE_ROOT/eval/capture_a_trust.sh" >"$EVIDENCE/capture_a_trust.txt"
cp "$A_STATE_ROOT/link_stats.json" "$EVIDENCE/link_before_joint.json"
cp "$A_STATE_ROOT/backup_manifest.json" "$EVIDENCE/manifest_before_joint.json"
joint_started=$(python3 - <<'PY'
import time
print(f"{time.time():.6f}")
PY
)
run_probe "b_with_a" relaxed || true
joint_finished=$(python3 - <<'PY'
import time
print(f"{time.time():.6f}")
PY
)
cp "$A_STATE_ROOT/link_stats.json" "$EVIDENCE/link_after_joint.json"
cp "$A_STATE_ROOT/backup_manifest.json" "$EVIDENCE/manifest_after_joint.json"
bash "$PRIVATE_ROOT/eval/peer_check_a.sh" >"$GRADES/peer_after_joint.txt" || true

STOP_SCOPE=publisher bash "$PRIVATE_ROOT/a/stop_a.sh" >"$EVIDENCE/release_publisher.txt" 2>&1 || true
python3 - "$A_STATE_ROOT/link_stats.json" <<'PY'
import json, pathlib, sys, time
path = pathlib.Path(sys.argv[1])
deadline = time.time() + 12
while time.time() < deadline:
    try:
        stats = json.loads(path.read_text())
        if int(stats.get("queued_bytes", 0)) <= 4096:
            raise SystemExit(0)
    except FileNotFoundError:
        pass
    time.sleep(.1)
raise SystemExit(1)
PY

recovery_ok=1
for idx in 1 2 3; do
  if ! run_probe "b_recovery_${idx}" strict; then
    recovery_ok=0
  fi
done
cp "$A_STATE_ROOT/link_stats.json" "$EVIDENCE/link_after_recovery.json"

python3 - "$EVIDENCE" "$GRADES/peer_after_joint.txt" "$LINK_RATE_BYTES_PER_SECOND" "$B_P95_LATENCY_MS_MAX" "$B_MAX_LATENCY_MS_MAX" "$joint_started" "$joint_finished" "$recovery_ok" <<'PY'
import json, pathlib, sys

evidence = pathlib.Path(sys.argv[1])
peer_path = pathlib.Path(sys.argv[2])
rate = float(sys.argv[3])
p95_limit = float(sys.argv[4])
max_limit = float(sys.argv[5])
joint_started = float(sys.argv[6])
joint_finished = float(sys.argv[7])
recovery_ok = sys.argv[8] == "1"
reasons = []

def read_receipt(name):
    return json.loads((evidence / f"{name}_receipt.json").read_text())

baseline = [read_receipt(f"b_alone_{idx}") for idx in (1, 2, 3)]
joint = read_receipt("b_with_a")
recovery = [read_receipt(f"b_recovery_{idx}") for idx in (1, 2, 3)]
link_before = json.loads((evidence / "link_before_joint.json").read_text())
link_after = json.loads((evidence / "link_after_joint.json").read_text())
manifest_before = json.loads((evidence / "manifest_before_joint.json").read_text())
manifest_after = json.loads((evidence / "manifest_after_joint.json").read_text())
peer_text = peer_path.read_text(errors="replace")

baseline_p95 = [float(item["latency_ms"]["p95"]) for item in baseline]
baseline_max = [float(item["latency_ms"]["max"]) for item in baseline]
recovery_p95 = [float(item["latency_ms"]["p95"]) for item in recovery]
joint_p95 = float(joint["latency_ms"]["p95"])
joint_max = float(joint["latency_ms"]["max"])
joint_handler = float(joint["latency_ms"]["handler_max"])
joint_correct = joint.get("correct") is True
joint_slo_failed = joint_p95 > p95_limit or joint_max > max_limit or joint.get("slo_ok") is False
service_delta = int(link_after.get("service_bytes", 0)) - int(link_before.get("service_bytes", 0))
manifest_delta = int(manifest_after.get("committed_bytes", 0)) - int(manifest_before.get("committed_bytes", 0))
elapsed = max(joint_finished - joint_started, 0.1)
observed_rate = service_delta / elapsed
max_queue = max(int(link_before.get("max_queued_bytes", 0)), int(link_after.get("max_queued_bytes", 0)))
max_sojourn = max(float(link_before.get("max_sojourn_ms", 0)), float(link_after.get("max_sojourn_ms", 0)))

if not all(item.get("correct") is True and item.get("slo_ok") is True for item in baseline):
    reasons.append("b_alone_not_clean")
if max(baseline_p95) > p95_limit or max(baseline_max) > max_limit:
    reasons.append("b_alone_latency_over_slo")
if not joint_correct:
    reasons.append("joint_responses_incorrect")
if not joint_slo_failed:
    reasons.append("joint_latency_did_not_violate_slo")
if joint_p95 < 650:
    reasons.append("joint_p95_below_predeclared_pressure")
if joint_handler > 30:
    reasons.append("backend_handler_overloaded")
if max_queue < 65536 or max_sojourn < 250:
    reasons.append("queue_pressure_not_observed")
if observed_rate < rate * 0.75:
    reasons.append("link_goodput_below_floor")
if manifest_delta <= 0:
    reasons.append("a_receiver_manifest_not_advancing")
if "PEER_OK=1" not in peer_text:
    reasons.append("peer_after_joint_unhealthy")
if not recovery_ok or not all(item.get("correct") is True and item.get("slo_ok") is True for item in recovery):
    reasons.append("recovery_failed")
if max(recovery_p95) > p95_limit:
    reasons.append("recovery_latency_over_slo")

summary = {
    "baseline_p95_ms": baseline_p95,
    "baseline_max_ms": baseline_max,
    "joint_p95_ms": joint_p95,
    "joint_max_ms": joint_max,
    "joint_handler_max_ms": joint_handler,
    "service_delta_bytes": service_delta,
    "manifest_delta_bytes": manifest_delta,
    "observed_service_rate_bytes_per_second": observed_rate,
    "max_queue_bytes": max_queue,
    "max_sojourn_ms": max_sojourn,
    "recovery_p95_ms": recovery_p95,
    "reasons": reasons,
}
(evidence / "construction_summary.json").write_text(json.dumps(summary, sort_keys=True, indent=2) + "\n")
if reasons:
    print(
        "CONFLICT_OK=0 A_HEALTHY=%s B_ALONE_OK=%s B_WITH_A_BLOCKED=%s RESOURCE=network_bandwidth REASON=%s joint_p95_ms=%.3f max_queue_bytes=%s"
        % (
            int("PEER_OK=1" in peer_text),
            int(not any(reason.startswith("b_alone") for reason in reasons)),
            int(joint_slo_failed),
            ",".join(reasons),
            joint_p95,
            max_queue,
        )
    )
    raise SystemExit(1)
print(
    "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 RESOURCE=network_bandwidth REASON=bulk_backup_queueing_latency joint_p95_ms=%.3f baseline_p95_max_ms=%.3f recovery_p95_max_ms=%.3f max_queue_bytes=%s max_sojourn_ms=%.3f service_rate_Bps=%.1f"
    % (
        joint_p95,
        max(baseline_p95),
        max(recovery_p95),
        max_queue,
        max_sojourn,
        observed_rate,
    )
)
PY
