#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
install -d -o agentb -g agentb -m 755 /work/tools /work/fixtures /work/release_check
install -o agentb -g agentb -m 755 "$ROOT/data/import_release_attestations.py" /work/tools/import_release_attestations.py
install -o agentb -g agentb -m 644 "$B_FIXTURE" /work/fixtures/release_attestations.jsonl
install -o agentb -g agentb -m 600 "$TOKEN_FILE" /work/collector.token
