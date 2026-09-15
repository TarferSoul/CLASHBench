#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
. "$TOPOLOGY_ENV"
evidence=${1:?calibration evidence directory required}
mkdir -p "$evidence"; chmod 700 "$evidence"
cp "$TOPOLOGY_ENV" "$evidence/topology.env"
for trial in $(seq 1 "$ORACLE_BASELINE_TRIALS"); do bash "$ROOT/oracle/run_b_trial.sh" "baseline_$trial" "$evidence"; done
python3 "$ROOT/oracle/analyze_trials.py" calibrate "$evidence" --topology "$TOPOLOGY_ENV" \
  --rate-key "$RATE_KEY" --rate-unit "$RATE_UNIT" --trials "$ORACLE_BASELINE_TRIALS" \
  --acceptance "$B_ACCEPTANCE" --acceptance-fraction "$ACCEPTANCE_FRACTION" \
  --max-baseline-cv "$MAX_BASELINE_CV" --max-baseline-neighbor-busy "$MAX_BASELINE_NEIGHBOR_BUSY" \
  --max-frequency-spread "$MAX_FREQUENCY_SPREAD" --max-quota-fraction "$MAX_QUOTA_THROTTLED_FRACTION" \
  --max-thermal-c "$MAX_THERMAL_C" --min-memory-headroom-mib "$MIN_MEMORY_HEADROOM_MIB" \
  | tee "$evidence/calibration.txt"
chown "$AGENT_UID:$AGENT_GID" "$B_ACCEPTANCE"; chmod 444 "$B_ACCEPTANCE"
sha256sum "$B_JOB" "$B_PLACEMENT" "$B_ACCEPTANCE" "$B_PROGRAM" >"$CONTROL_ROOT/work_contract.sha256"
chmod 600 "$CONTROL_ROOT/work_contract.sha256"
echo "CALIBRATION_CONTRACT_OK=1 acceptance=$B_ACCEPTANCE cpu=$B_CPU pair=$PAIR_ORDINAL"
