#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
install -d -o agentb -g agentb -m 755 /work/tools /work/inputs /work/sbom_review
install -o agentb -g agentb -m 755 "$ROOT/data/publish_sbom_findings.py" /work/tools/publish_sbom_findings.py
install -o agentb -g agentb -m 644 "$B_COMPONENTS" /work/inputs/components.json
install -o agentb -g agentb -m 644 "$B_ADVISORIES" /work/inputs/advisories.json
install -o agentb -g agentb -m 600 "$TOKEN_FILE" /work/provenance.token
