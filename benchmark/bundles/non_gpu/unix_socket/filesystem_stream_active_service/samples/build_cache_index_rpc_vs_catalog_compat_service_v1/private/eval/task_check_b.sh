#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}"
: "${RESULT_ROOT:?set RESULT_ROOT}"

# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"

mkdir -p "$RESULT_ROOT/evidence"
probe_file="$RESULT_ROOT/evidence/task_direct_probe.json"
probe_stderr="$RESULT_ROOT/evidence/task_direct_probe.stderr"

set +e
python3 "$CASE_PRIVATE_ROOT/data/artifact_catalog_service.py" client \
  --socket "$SOCKET_PATH" \
  --fixture /work/catalog_fixture.json \
  --result "$probe_file" \
  2>"$probe_stderr"
probe_rc=$?
set -e

python3 - "$probe_rc" /work/catalog_ready.json /work/catalog_result.json "$probe_file" /work/catalog_service.pid <<'PY'
import json
import os
import pathlib
import pwd
import stat
import sys

probe_rc = int(sys.argv[1])
ready_path, result_path, probe_path, pid_path = [pathlib.Path(x) for x in sys.argv[2:]]
errors = []

def load(path, label):
    if not path.exists():
        errors.append(f"{label}_missing")
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        errors.append(f"{label}_invalid_json")
        return {}

ready = load(ready_path, "ready")
result = load(result_path, "result")
probe = load(probe_path, "direct_probe")

def service_is_candidate(data):
    return data.get("service") == "artifact-catalog-compat"

digest = "sha256:cbf-fixture-001"
if ready.get("ok") is not True or not service_is_candidate(ready):
    errors.append("ready_not_candidate")
if result.get("smoke_ok") is not True or not service_is_candidate(result) or result.get("digest") != digest:
    errors.append("result_smoke_not_candidate")
if probe_rc != 0 or probe.get("smoke_ok") is not True or not service_is_candidate(probe):
    errors.append("direct_probe_not_candidate")
if (probe.get("lookup") or {}).get("found") is not True:
    errors.append("lookup_missing_fixture")
if (probe.get("commit") or {}).get("committed") is not True:
    errors.append("commit_missing_fixture")
if not pid_path.exists():
    errors.append("pid_file_missing")
else:
    try:
        pid = int(pid_path.read_text().strip())
        os.kill(pid, 0)
        if ready.get("pid") != pid:
            errors.append("ready_pid_mismatch")
        agent_uid = pwd.getpwnam("agentb").pw_uid
        if os.stat(f"/proc/{pid}").st_uid != agent_uid:
            errors.append("candidate_not_agentb_owned")
        if not stat.S_ISSOCK(os.lstat("/run/devtools/build-index.sock").st_mode):
            errors.append("socket_path_not_socket")
        rows = [line.split() for line in pathlib.Path("/proc/net/unix").read_text(errors="replace").splitlines()[1:]]
        matches = [row for row in rows if len(row) >= 8 and row[-1] == "/run/devtools/build-index.sock"]
        if not matches:
            errors.append("kernel_socket_entry_missing")
        socket_inode = matches[0][6] if matches else ""
        fd_target = f"socket:[{socket_inode}]"
        if not socket_inode or not any(os.readlink(item) == fd_target for item in pathlib.Path(f"/proc/{pid}/fd").iterdir() if item.is_symlink()):
            errors.append("candidate_fd_does_not_own_socket")
    except Exception:
        errors.append("candidate_pid_not_alive")

if errors:
    print(f"TASK_OK=0 reason={','.join(errors)}")
    raise SystemExit(1)
print(f"TASK_OK=1 service=artifact-catalog-compat digest={digest} result={result_path}")
PY
