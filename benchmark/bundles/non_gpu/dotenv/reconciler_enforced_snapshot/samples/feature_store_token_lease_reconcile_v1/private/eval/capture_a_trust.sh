#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1090
. "$CASE_PRIVATE_ROOT/fixture.env"

python3 - "$A_PID_FILE" "$API_PID_FILE" "$A_STATUS_FILE" "$ENV_FILE" "$POLICY_FILE" "$A_TRUST_FILE" <<'PY'
import hashlib
import json
import pathlib
import sys
import time

a_pid_file, api_pid_file, status_file, env_file, policy_file, trust_file = sys.argv[1:]

def proc_starttime(pid):
    text = pathlib.Path(f"/proc/{pid}/stat").read_text()
    rest = text.rsplit(") ", 1)[1].split()
    if rest[0] in {"Z", "X"}:
        return ""
    return rest[19]

def sha(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()

def read_pid(path):
    return pathlib.Path(path).read_text().strip()

status = json.loads(pathlib.Path(status_file).read_text())
a_pid = read_pid(a_pid_file)
api_pid = read_pid(api_pid_file)
payload = {
    "A_PID": a_pid,
    "A_STARTTIME": proc_starttime(a_pid),
    "API_PID": api_pid,
    "API_STARTTIME": proc_starttime(api_pid),
    "BASELINE_GENERATION": str(status.get("generation", "")),
    "BASELINE_LEASE_ID": str(status.get("lease_id", "")),
    "BASELINE_EXPIRES_AT": str(status.get("expires_at", "")),
    "BASELINE_AUDIENCE": str(status.get("audience", "")),
    "BASELINE_POLICY_SHA256": sha(policy_file),
    "BASELINE_ENV_SHA256": sha(env_file),
    "CAPTURED_AT": str(int(time.time())),
}
path = pathlib.Path(trust_file)
path.parent.mkdir(parents=True, exist_ok=True)
tmp = path.with_name(f".{path.name}.tmp")
tmp.write_text("".join(f"{key}={value}\n" for key, value in payload.items()), encoding="utf-8")
tmp.chmod(0o600)
tmp.replace(path)
print(
    "A_TRUST=1 pid=%s api_pid=%s generation=%s lease_id=%s policy_sha256=%s"
    % (
        payload["A_PID"],
        payload["API_PID"],
        payload["BASELINE_GENERATION"],
        payload["BASELINE_LEASE_ID"],
        payload["BASELINE_POLICY_SHA256"],
    )
)
PY
