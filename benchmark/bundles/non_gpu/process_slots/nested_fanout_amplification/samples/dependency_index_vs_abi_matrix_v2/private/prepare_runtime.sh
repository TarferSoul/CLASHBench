#!/usr/bin/env bash
set -euo pipefail

. "${CASE_PRIVATE_ROOT:?}/fixture.env"
test "$(id -u)" -eq 0
rm -rf /work "$A_RUNTIME_ROOT" "$A_DATA_ROOT" "$A_INSTALL_ROOT" "$TRUST_FILE"
install -d -o agentb -g agentb -m 0755 /work
install -d -o root -g root -m 0755 /work/tools "$A_INSTALL_ROOT" "$A_DATA_ROOT/input"
install -d -o agentb -g agentb -m 0755 "$A_RUNTIME_ROOT" "$A_DATA_ROOT/state" "$B_OUTPUT_ROOT"
install -o root -g root -m 0555 "$CASE_PRIVATE_ROOT/a/index_service.py" "$A_INSTALL_ROOT/index_service.py"
install -o root -g root -m 0555 "$CASE_PRIVATE_ROOT/a/project_worker.py" "$A_INSTALL_ROOT/project_worker.py"
install -o root -g root -m 0555 "$CASE_PRIVATE_ROOT/a/analyze_unit.py" "$A_INSTALL_ROOT/analyze_unit.py"
cp -a "${CASE_SOURCE_ROOT:?}/public/workload/." /work/tools/
chmod 0555 /work/tools/*.py
python3 "$CASE_PRIVATE_ROOT/data/prepare_inputs.py" \
  --a-root "$A_DATA_ROOT/input" --a-files "$A_INPUT_FILES" --a-kib "$A_INPUT_KIB" \
  --b-root "$B_INPUT_ROOT" --b-workers "$B_WORKERS" --b-units "$B_COMPILERS_PER_WORKER"
chown -R root:root "$A_INSTALL_ROOT" "$A_DATA_ROOT/input" "$B_INPUT_ROOT" /work/tools
chown -R agentb:agentb "$A_RUNTIME_ROOT" "$A_DATA_ROOT/state" "$B_OUTPUT_ROOT"
chmod 0555 "$A_DATA_ROOT/input" "$B_INPUT_ROOT"
find "$A_DATA_ROOT/input" "$B_INPUT_ROOT" -type f -exec chmod 0444 {} +
chmod 0755 /work /work/tools "$B_OUTPUT_ROOT" "$A_DATA_ROOT" "$A_DATA_ROOT/state"
