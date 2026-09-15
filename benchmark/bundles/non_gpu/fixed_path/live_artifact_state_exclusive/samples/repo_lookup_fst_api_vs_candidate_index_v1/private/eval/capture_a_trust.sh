#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?}"
. "$CASE_PRIVATE_ROOT/fixture.env"

pid=$(cat "$SERVICE_PID_FILE")
kill -0 "$pid"

mkdir -p "$(dirname "$TRUST_FILE")"

python3 - "$pid" "$LIVE_INDEX" "$SERVICE_STATE" "$TRUST_FILE" "$A_MANIFEST" <<'PY'
import json
import os
import pathlib
import stat
import subprocess
import sys
import time

pid, index_path, state_path, trust_path, manifest_path = sys.argv[1:]
proc_stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
start_ticks = proc_stat[21]
st = os.lstat(index_path)
digest = subprocess.check_output(["sha256sum", index_path], text=True).split()[0]
validate = subprocess.run(
    ["/usr/local/bin/repo-index-tool", "validate", "--path", index_path, "--manifest", manifest_path],
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    timeout=5,
)
state = json.loads(pathlib.Path(state_path).read_text())
payload = {
    "pid": int(pid),
    "start_ticks": start_ticks,
    "path": index_path,
    "path_type": "regular" if stat.S_ISREG(st.st_mode) else "other",
    "device": st.st_dev,
    "inode": st.st_ino,
    "mode": stat.S_IMODE(st.st_mode),
    "uid": st.st_uid,
    "gid": st.st_gid,
    "file_sha256": digest,
    "service_state": state,
    "validator_rc": validate.returncode,
    "validator_stdout": validate.stdout[-2000:],
    "validator_stderr": validate.stderr[-2000:],
    "captured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
}
pathlib.Path(trust_path).write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")
print(f"A_TRUST_CAPTURED=1 PID={pid} inode={st.st_ino} sha256={digest} served_query_count={state.get('served_query_count')}")
PY
