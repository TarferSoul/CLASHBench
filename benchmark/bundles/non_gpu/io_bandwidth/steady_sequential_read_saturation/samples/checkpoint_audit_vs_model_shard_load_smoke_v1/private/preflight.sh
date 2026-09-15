#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:?}}"
set -a
# shellcheck disable=SC1090
. "$ROOT/fixture.env"
set +a
export PRIVATE_CASE="$ROOT"
export CASE_PRIVATE_ROOT="$ROOT"

mkdir -p "$RESULT_ROOT/evidence"
python3 "$ROOT/data/checkpoint_fixture.py" prepare >"$RESULT_ROOT/evidence/fixture_prepare.json"
python3 "$ROOT/data/checkpoint_fixture.py" calibrate --trials "$CALIBRATION_TRIALS" >"$RESULT_ROOT/evidence/fixture_calibration.json"
df -h /work /work/artifact_volume >"$RESULT_ROOT/evidence/df_after_prepare.txt" 2>&1 || true
findmnt -T /work >"$RESULT_ROOT/evidence/findmnt_work.txt" 2>&1 || true
python3 "$ROOT/data/checkpoint_fixture.py" identity >"$RESULT_ROOT/evidence/path_identity.json"
echo "PREFLIGHT_OK=1"
