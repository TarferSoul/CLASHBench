#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

install -o root -g root -m 0755 "$ROOT/data/artifactctl.py" /usr/local/bin/artifactctl
install -o root -g root -m 0700 "$ROOT/data/artifact_registry_api.py" "$FIXTURE_INSTALL_ROOT/$FIXTURE_SERVER_NAME"
install -o root -g root -m 0755 "$ROOT/a/registry_session_bootstrap.py" "$A_WORKER_PATH"
install -o agentb -g agentb -m 0644 "$ROOT/data/emergency-registry-context.json" /work/emergency-registry-context.json
install -o agentb -g agentb -m 0644 "$ROOT/data/emergency-sbom-attestation.json" /work/emergency-sbom-attestation.json
