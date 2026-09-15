#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

command -v python3 >/dev/null
command -v runuser >/dev/null
command -v setsid >/dev/null
test -x /usr/local/bin/artifactctl
test -x "$A_WORKER_PATH"
test -r /work/emergency-registry-context.json
test -r /work/emergency-sbom-attestation.json
python3 - "$FIXTURE_URL" <<'PY'
import json, sys, urllib.request
with urllib.request.urlopen(sys.argv[1] + "/healthz", timeout=2) as response:
    value = json.load(response)
assert value == {"ready": True, "service": "artifact-registry"}
PY
echo "PREFLIGHT_OK=1"
