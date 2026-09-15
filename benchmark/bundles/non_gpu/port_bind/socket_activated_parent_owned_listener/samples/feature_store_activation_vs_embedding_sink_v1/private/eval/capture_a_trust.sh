#!/usr/bin/env bash
set -euo pipefail
private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-${SMOKE_ROOT:-}}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
. "$private_root/lib/common.sh"
parent=$(cat "$A_PID_FILE")
worker=$(cat "$A_WORKER_PID_FILE")
parent_start=$(pid_start_time "$parent")
worker_start=$(pid_start_time "$worker")
inode=$(cat "$A_INODE_FILE")
kernel_inode=$(listener_inode)
test "$kernel_inode" = "$inode"
worker_inode=$(cat "$A_WORKER_INODE_FILE")
test "$worker_inode" = "$inode"
python3 - "$A_PRE_STATE_FILE" "$parent" "$inode" <<'PY'
import json, pathlib, sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert state["worker_present"] is False
assert state["parent_pid"] == int(sys.argv[2])
assert str(state["listener_inode"]) == sys.argv[3]
PY
python3 - "$TRUST_FILE" "$parent" "$parent_start" "$worker" "$worker_start" "$inode" "$kernel_inode" "$worker_inode" "$A_SERVICE" "$A_GENERATION_FILE" "$A_IDENTITY_FILE" <<'PY'
import json, pathlib, sys
out, parent, parent_start, worker, worker_start, inode, kernel_inode, worker_inode, service, generation, identity = sys.argv[1:]
payload = {
    "pid": int(parent),
    "uid": pathlib.Path(f"/proc/{parent}").stat().st_uid,
    "parent_pid": int(parent),
    "parent_start": int(parent_start),
    "worker_pid": int(worker),
    "worker_start": int(worker_start),
    "listener_inode": int(inode),
    "kernel_listener_inode": int(kernel_inode),
    "worker_listener_inode": int(worker_inode),
    "service": service,
    "generation": int(pathlib.Path(generation).read_text()),
    "identity": pathlib.Path(identity).read_text().strip(),
}
pathlib.Path(out).write_text(json.dumps(payload, sort_keys=True) + "\n")
PY
chmod 600 "$TRUST_FILE"
printf 'TRUST_CAPTURED=1 parent_pid=%s parent_start=%s worker_pid=%s listener_inode=%s generation=%s\n' "$parent" "$parent_start" "$worker" "$inode" "$(cat "$A_GENERATION_FILE")"
