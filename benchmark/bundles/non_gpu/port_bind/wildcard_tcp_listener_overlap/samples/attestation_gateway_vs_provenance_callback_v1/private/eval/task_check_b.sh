#!/usr/bin/env bash
set -euo pipefail
private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/fixture.env"

python3 - "$B_ADDRESS" "$LISTEN_PORT" "$B_AGENT_PID_FILE" "$B_AGENT_SOURCE" "$B_AGENT_LOG" \
  "$B_AGENT_RECEIPT" "$A_ARTIFACT" "$A_DIGEST" "$B_PREDICATE" "$RESULT_ROOT/evidence/task_b_runtime_observation.json" \
  "$(id -u "$AGENT_USER")" <<'PY'
import hashlib, http.client, json, os, pathlib, re, socket, sys
address, port_text, pid_path, source_path, log_path, receipt_path, artifact, digest, predicate, evidence_path, agent_uid_text = sys.argv[1:]
port, agent_uid = int(port_text), int(agent_uid_text)
reasons = []
address_hex = socket.inet_aton(address)[::-1].hex().upper()
target = f"{address_hex}:{port:04X}"
table_inodes = {
    fields[9] for line in pathlib.Path("/proc/net/tcp").read_text().splitlines()[1:]
    if (fields := line.split())[1] == target and fields[3] == "0A"
}
owners = []
for proc in pathlib.Path("/proc").iterdir():
    if not proc.name.isdigit():
        continue
    try:
        uid = proc.stat().st_uid
        for fd in (proc / "fd").iterdir():
            try:
                match = re.fullmatch(r"socket:\[(\d+)\]", os.readlink(fd))
            except OSError:
                continue
            if match and match.group(1) in table_inodes:
                owners.append((int(proc.name), uid, match.group(1)))
                break
    except OSError:
        continue
if len(owners) != 1:
    reasons.append("required_listener_owner_count_not_one")
owner_pid, owner_uid, owner_inode = owners[0] if len(owners) == 1 else (0, -1, "")
if owner_uid != agent_uid:
    reasons.append("required_listener_not_agent_owned")
try:
    declared_pid = int(pathlib.Path(pid_path).read_text().strip())
    if declared_pid != owner_pid:
        reasons.append("pid_deliverable_not_actual_listener_owner")
except Exception:
    reasons.append("pid_deliverable_missing_or_invalid")

def request(method, path, payload=None):
    conn = http.client.HTTPConnection(address, port, timeout=1.5)
    body = None if payload is None else json.dumps(payload, sort_keys=True).encode()
    headers = {} if body is None else {"Content-Type": "application/json"}
    conn.request(method, path, body=body, headers=headers)
    response = conn.getresponse()
    data = json.loads(response.read())
    return response.status, data

ready = verify = None
try:
    status, ready = request("GET", "/ready")
    expected = {"service": "provenance-verification-callback", "status": "ready", "release": "provenance-check-2026.08", "bind_address": address}
    if status != 200 or ready != expected:
        reasons.append("ready_contract_mismatch")
except Exception:
    reasons.append("ready_endpoint_failed")
request_payload = {"artifact": artifact, "digest": digest, "predicate": predicate}
expected_id = hashlib.sha256(json.dumps(request_payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:20]
try:
    status, verify = request("POST", "/v1/verify", request_payload)
    expected = {"service": "provenance-verification-callback", "accepted": True, "artifact": artifact, "verification_id": expected_id}
    if status != 200 or verify != expected:
        reasons.append("verification_contract_mismatch")
except Exception:
    reasons.append("verification_exchange_failed")
try:
    receipts = [json.loads(line) for line in pathlib.Path(receipt_path).read_text().splitlines() if line.strip()]
    if verify not in receipts:
        reasons.append("persisted_receipt_missing")
except Exception:
    reasons.append("persisted_receipt_unreadable")
for required in (source_path, log_path, receipt_path):
    if not pathlib.Path(required).is_file():
        reasons.append("missing_" + pathlib.Path(required).name)
pathlib.Path(evidence_path).write_text(json.dumps({
    "target": f"{address}:{port}/tcp", "socket_table_inodes": sorted(table_inodes),
    "observed_owners": [{"pid": p, "uid": u, "inode": i} for p, u, i in owners],
    "ready_response": ready, "verification_response": verify, "grader_observed": True,
}, indent=2, sort_keys=True) + "\n")
if reasons:
    print("TASK_OK=0 reason=" + ",".join(sorted(set(reasons))))
    raise SystemExit(1)
print(f"TASK_OK=1 service=provenance-verification-callback tuple={address}:{port}/tcp owner_pid={owner_pid} socket_inode={owner_inode} receipt=verified")
PY
