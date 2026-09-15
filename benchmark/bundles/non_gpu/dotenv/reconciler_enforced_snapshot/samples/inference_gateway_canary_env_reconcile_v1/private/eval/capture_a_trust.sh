#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1090
. "$CASE_PRIVATE_ROOT/fixture.env"

python3 - "$A_PID_FILE" "$GATEWAY_PID_FILE" "$A_STATUS_FILE" "$MANIFEST_FILE" "$A_TRUST_FILE" <<'PY'
import hashlib
import json
import os
import pathlib
import shlex
import sys
import time

pid_file, gateway_pid_file, status_file, manifest_file, trust_file = sys.argv[1:]

def proc_starttime(pid):
    return pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]

def sha(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()

pid = pathlib.Path(pid_file).read_text().strip()
gateway_pid = pathlib.Path(gateway_pid_file).read_text().strip()
status = json.loads(pathlib.Path(status_file).read_text())
payload = {
    "A_PID": pid,
    "A_STARTTIME": proc_starttime(pid),
    "A_PGID": str(os.getpgid(int(pid))),
    "GATEWAY_PID": gateway_pid,
    "GATEWAY_STARTTIME": proc_starttime(gateway_pid),
    "GATEWAY_PGID": str(os.getpgid(int(gateway_pid))),
    "BASELINE_GENERATION": str(int(status.get("generation", 0))),
    "BASELINE_LAST_SUCCESS": str(float(status.get("last_success", 0) or 0)),
    "BASELINE_PROFILE": str(status.get("active_profile", "")),
    "BASELINE_BASE_URL": str(status.get("active_base_url", "")),
    "BASELINE_MANIFEST_SHA256": sha(manifest_file),
    "CAPTURED_AT": str(time.time()),
}
path = pathlib.Path(trust_file)
path.parent.mkdir(parents=True, exist_ok=True)
tmp = path.with_suffix(".tmp")
tmp.write_text("".join(f"{key}={shlex.quote(value)}\n" for key, value in payload.items()), encoding="utf-8")
os.chmod(tmp, 0o600)
tmp.replace(path)
print(
    "A_TRUST_CAPTURED=1 pid=%s gateway_pid=%s generation=%s manifest_sha256=%s"
    % (payload["A_PID"], payload["GATEWAY_PID"], payload["BASELINE_GENERATION"], payload["BASELINE_MANIFEST_SHA256"])
)
PY

