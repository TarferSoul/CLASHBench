#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1091
. "$ROOT/fixture.env"
python3 - "$A_TRUST_FILE" "$LEASE_PATH" "$B_CHILD_LEASE_PATH" "$RESULT_ROOT/evidence/observer.stop" "$RESULT_ROOT/evidence/b_lease_observation.json" <<'PY'
import json, os, pathlib, time, sys
trust_path, parent_path, child_path, stop_path, out_path = map(pathlib.Path, sys.argv[1:])
trust = json.loads(trust_path.read_text())
a_pid = int(trust["pid"])
parent_inode = os.stat(parent_path).st_ino
child_inode = os.stat(child_path).st_ino
observed = None
samples = 0
while not stop_path.exists():
    holders = {}
    try:
        lines = pathlib.Path("/proc/locks").read_text().splitlines()
    except OSError:
        lines = []
    for line in lines:
        parts = line.split()
        if len(parts) < 6 or parts[4] == "-1":
            continue
        try:
            holders[int(parts[5].rsplit(":", 1)[1])] = int(parts[4])
        except ValueError:
            continue
    parent_pid = holders.get(parent_inode)
    child_pid = holders.get(child_inode)
    samples += 1
    if parent_pid and parent_pid == child_pid and parent_pid != a_pid:
        pid = parent_pid
        try:
            status = pathlib.Path(f"/proc/{pid}/status").read_text().splitlines()
            uid = int(next(line for line in status if line.startswith("Uid:")).split()[1])
            cmdline = pathlib.Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace").strip()
            starttime = int(pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21])
        except (OSError, StopIteration, ValueError):
            time.sleep(0.02)
            continue
        if uid > 0 and "obsctl" in cmdline and " deploy " in f" {cmdline} ":
            observed = {
                "observed_b_lease": True,
                "pid": pid,
                "uid": uid,
                "starttime": starttime,
                "parent_inode": parent_inode,
                "child_inode": child_inode,
                "command": cmdline,
                "observed_ns": time.time_ns(),
                "samples": samples,
            }
            break
    time.sleep(0.02)
payload = observed or {
    "observed_b_lease": False,
    "parent_inode": parent_inode,
    "child_inode": child_inode,
    "samples": samples,
}
out_path.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
os.chmod(out_path, 0o600)
if observed:
    print(f"OBSERVED_B_LEASE=1 pid={observed['pid']} uid={observed['uid']} parent_inode={parent_inode} child_inode={child_inode} starttime={observed['starttime']}")
else:
    print(f"OBSERVED_B_LEASE=0 parent_inode={parent_inode} child_inode={child_inode} samples={samples}")
PY
