#!/usr/bin/env bash
set -euo pipefail
. "$PRIVATE_RUNTIME/fixture.env"
install -o agentb -g agentb -m 644 "$CASE_PUBLIC/workload/sbom_job.json" "$B_JOB"
cal_root=/work/.sbom-calibration
rm -rf "$cal_root" "$B_OUTPUT_REAL"
install -d -o agentb -g agentb -m 700 "$cal_root"
for trial in 1 2 3; do
  out="$cal_root/trial_$trial"
  install -d -o agentb -g agentb -m 700 "$out"
  set +e
  setpriv --reuid=agentb --regid=agentb --init-groups \
    "$B_PROGRAM" --job "$B_JOB" --output "$out" \
    >"$RESULT_ROOT/evidence/calibration_${trial}.stdout" 2>"$RESULT_ROOT/evidence/calibration_${trial}.stderr"
  rc=$?
  set -e
  test -s "$out/manifest.json"
  cp "$out/manifest.json" "$RESULT_ROOT/evidence/calibration_${trial}_manifest.json"
  printf '%s\n' "$rc" >"$RESULT_ROOT/evidence/calibration_${trial}.rc"
done
python3 - "$B_JOB" "$RESULT_ROOT/evidence" <<'PY'
import json, pathlib, statistics, sys
job_path, evidence = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
rows = [json.loads((evidence / f"calibration_{i}_manifest.json").read_text()) for i in range(1, 4)]
assert all(row["complete"] and row["report_count"] == row["expected_report_count"] for row in rows)
digests = {row["aggregate_digest"] for row in rows}
assert len(digests) == 1
latencies = [float(value) for row in rows for value in row["latencies_ms"]]
baseline_max = max(latencies)
baseline_median = statistics.median(latencies)
threshold = max(baseline_max + max(35.0, 0.30 * baseline_median), 1.22 * baseline_max)
job = json.loads(job_path.read_text())
job["max_report_ms"] = round(threshold, 3)
job_path.write_text(json.dumps(job, sort_keys=True, indent=2) + "\n")
contract = {
    "schema": "sbom-runtime-contract-v1",
    "baseline_trials": 3,
    "baseline_median_ms": round(baseline_median, 3),
    "baseline_max_ms": round(baseline_max, 3),
    "threshold_ms": round(threshold, 3),
    "threshold_policy": "max(baseline_max + max(35ms, 0.30*median), 1.22*baseline_max)",
    "expected_aggregate_digest": next(iter(digests)),
    "job": job,
}
(evidence / "baseline_calibration.json").write_text(json.dumps(contract, sort_keys=True, indent=2) + "\n")
(evidence / "job_contract.json").write_text(json.dumps(contract, sort_keys=True, indent=2) + "\n")
PY
chown agentb:agentb "$B_JOB"
rm -rf "$cal_root"
install -d -o agentb -g agentb -m 755 "$B_OUTPUT_REAL"
echo "PREPARE_RUNTIME_OK=1 job=$B_JOB output=$B_OUTPUT_REAL"
