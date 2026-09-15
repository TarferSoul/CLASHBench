#!/usr/bin/env bash
set -euo pipefail
PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$PRIVATE_ROOT/fixture.env"
. "$LANE_CONFIG"
: "${RESULT_ROOT:?}"
evidence="$RESULT_ROOT/evidence/agent_b_calibration"
cal=/dev/shm/sbom-agent-b-calibration
rm -rf "$evidence" "$cal" "$B_OUTPUT_DIR"
install -d -o root -g root -m 700 "$evidence"
install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 700 "$cal" "$B_OUTPUT_DIR"
for index in 1 2 3; do
  setpriv --reuid="$SERVICE_USER" --regid="$SERVICE_USER" --init-groups \
    env -i PATH="$FIXED_PATH" HOME=/work \
    "$LANE_WRAPPER" python3 "$B_PROGRAM" --input "$B_INPUT" \
      --rate-seconds "$B_RATE_SECONDS" --rate-output "$cal/rate_$index.json"
done
python3 - "$cal" "$B_JOB" "$B_INPUT" "$CPU_LIST" "$B_JOB_WINDOW_SECONDS" "$B_JOB_TARGET_FRACTION" <<'PY'
import hashlib, json, pathlib, statistics, sys
cal, job, source, lane, window, fraction = sys.argv[1:]
rates = [json.loads(path.read_text())["rounds_per_second"] for path in sorted(pathlib.Path(cal).glob("rate_*.json"))]
payload = {
    "schema": "attestation-delta-job-v1",
    "input_digest": hashlib.sha256(pathlib.Path(source).read_bytes()).hexdigest(),
    "lane_cpus": [int(x) for x in lane.split(",")],
    "required_rounds": max(1, int(statistics.median(rates) * float(window) * float(fraction))),
    "deadline_seconds": float(window),
    "calibrated_median_rounds_per_second": statistics.median(rates),
    "target_fraction": float(fraction),
}
pathlib.Path(job).write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
print(json.dumps(payload, sort_keys=True))
PY
chown "$SERVICE_USER:$SERVICE_USER" "$B_JOB"
setpriv --reuid="$SERVICE_USER" --regid="$SERVICE_USER" --init-groups \
  env -i PATH="$FIXED_PATH" HOME=/work \
  "$LANE_WRAPPER" python3 "$B_PROGRAM" --input "$B_INPUT" --job "$B_JOB" --output-dir "$B_OUTPUT_DIR"
cp "$B_REPORT" "$cal/baseline_job_report.json"
cp "$cal"/rate_*.json "$cal/baseline_job_report.json" "$evidence/"
chmod -R go-rwx "$evidence"
rm -rf "$B_OUTPUT_DIR"
mkdir -p "$B_OUTPUT_DIR"
chown "$SERVICE_USER:$SERVICE_USER" "$B_OUTPUT_DIR"
rm -rf "$cal"
echo "B_CALIBRATION_OK=1 lane=$CPU_LIST trials=3"
