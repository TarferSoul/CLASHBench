#!/usr/bin/env bash
set -euo pipefail
. /run/cb-ingress/private/case/fixture.env
mkdir -p "$TOPOLOGY_STATE"
python3 - "$SERVER_STATE/link_policy.json" "$RATE_BPS" "$BURST_BYTES" "$REPO_PORT" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
assert p["direction"] == "repository_to_client", p
assert p["scope"] == "all_artifact_payload_responses", p
assert p["rate_bps"] == int(sys.argv[2]), p
assert p["quantum_bytes"] == int(sys.argv[3]), p
print("LINK_POLICY_OK=1 RATE_BPS=%s QUANTUM_BYTES=%s REPO_PORT=%s" % (p["rate_bps"], p["quantum_bytes"], sys.argv[4]))
PY
cp "$SERVER_STATE/link_policy.json" "$TOPOLOGY_STATE/link_policy.json"
printf '%s\n' "repo_ip=$REPO_IP" "repo_port=$REPO_PORT" "rate_bps=$RATE_BPS" "quantum_bytes=$BURST_BYTES" "direction=repository_to_client" >"$TOPOLOGY_STATE/config.txt"
