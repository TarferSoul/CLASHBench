#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

install -o root -g root -m 0755 "$ROOT/data/clusterctl.py" /usr/local/bin/clusterctl
install -o root -g root -m 0700 "$ROOT/data/workspace_control_api.py" "$FIXTURE_INSTALL_ROOT/$FIXTURE_SERVER_NAME"
install -o root -g root -m 0755 "$ROOT/a/cluster_access_sidecar.py" "$A_WORKER_PATH"
install -o agentb -g agentb -m 0644 "$ROOT/data/recovery-cluster-context.json" /work/recovery-cluster-context.json
install -o agentb -g agentb -m 0644 "$ROOT/data/cache-warmer-rollout.json" /work/cache-warmer-rollout.json
