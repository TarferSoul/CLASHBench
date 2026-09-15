#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
. "$ROOT/fixture.env"
command -v python3 >/dev/null
command -v runuser >/dev/null
command -v timeout >/dev/null
command -v tc >/dev/null
python3 -m py_compile "$ROOT/data/egress_gateway.py" "$ROOT/data/artifact_receiver.py" "$ROOT/data/continuous_publisher.py" "$ROOT/data/upload_client.py" "$ROOT/data/reverse_probe.py"
python3 - "$ROOT/fixture.json" "$ROOT/data/upload_spec.json" <<'PY'
import hashlib, json, pathlib, sys

def payload(label, size):
    out=bytearray(); counter=0
    while len(out)<size:
        out.extend(hashlib.sha256(f"{label}:{counter}".encode()).digest()); counter+=1
    return bytes(out[:size])

fixture=json.loads(pathlib.Path(sys.argv[1]).read_text())
spec=json.loads(pathlib.Path(sys.argv[2]).read_text())
parts=[]
for part in spec["parts"]:
    data=payload(f"{spec['artifact']}:{part['name']}", int(part["size"]))
    assert hashlib.sha256(data).hexdigest()==part["sha256"]
    parts.append(data)
assert hashlib.sha256(b"".join(parts)).hexdigest()==spec["aggregate_sha256"]
assert fixture["gateway"]==spec["gateway"]
print("FIXTURE_JSON_OK=1")
PY
printf 'NETWORK_MODE=root_configured_directional_userspace_gateway\n' >"${RESULT_ROOT:?}/evidence/network_mode.txt"
tc -s qdisc show dev lo >"$RESULT_ROOT/evidence/qdisc_preflight.txt" 2>&1 || true
echo "PREFLIGHT_OK=1 gateway=$GATEWAY_HOST:$GATEWAY_PORT backend=$BACKEND_HOST:$BACKEND_PORT rate_Bps=$EGRESS_RATE_BYTES_PER_SECOND"

