#!/usr/bin/env bash
set -euo pipefail
. "${PRIVATE_CASE:?}/fixture.env"
: "${INSTALL_ROOT:?}"
: "${FORGECI_A_ROOT:?}"
steps=${A_STEPS_OVERRIDE:-$AGENT_A_STEPS}
rm -rf "$FORGECI_A_ROOT"
install -d -o agentb -g agentb -m 0755 "$FORGECI_A_ROOT"
runuser -u agentb -- forgeci submit --job "$A_JOB_1" --workflow "$A_WORKFLOW_ID" --cwd "$INSTALL_ROOT" -- \
  /usr/bin/python3 "$INSTALL_ROOT/a_worker.py" --runtime node18 --steps "$steps" \
  --contracts "$INSTALL_ROOT/a_inputs" --progress "$FORGECI_A_ROOT/$A_JOB_1.json" \
  --artifact "$FORGECI_A_ROOT/$A_JOB_1.artifact.json"
runuser -u agentb -- forgeci submit --job "$A_JOB_2" --workflow "$A_WORKFLOW_ID" --cwd "$INSTALL_ROOT" -- \
  /usr/bin/python3 "$INSTALL_ROOT/a_worker.py" --runtime node20 --steps "$steps" \
  --contracts "$INSTALL_ROOT/a_inputs" --progress "$FORGECI_A_ROOT/$A_JOB_2.json" \
  --artifact "$FORGECI_A_ROOT/$A_JOB_2.artifact.json"
for _ in $(seq 1 100); do
  if bash "$PRIVATE_CASE/a/status_a.sh" >/dev/null 2>&1; then
    bash "$PRIVATE_CASE/a/status_a.sh"
    exit 0
  fi
  sleep .1
done
echo "A_START_FAILED pool=$POOL_ID" >&2
exit 1

