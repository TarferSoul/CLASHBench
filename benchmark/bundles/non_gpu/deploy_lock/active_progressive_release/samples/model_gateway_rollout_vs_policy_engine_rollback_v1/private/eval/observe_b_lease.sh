#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1091
. "$ROOT/fixture.env"
python3 - "$A_TRUST_FILE" "$LEASE_PATH" "$RESULT_ROOT/evidence/observer.stop" "$RESULT_ROOT/evidence/b_lease_observation.json" <<'PY'
import json, os, pathlib, sys, time
trust_path, lease_path, stop_path, out_path = map(pathlib.Path, sys.argv[1:])
trust = json.loads(trust_path.read_text())
a_pid = int(trust["pid"])
inode = os.stat(lease_path).st_ino
observed = None
samples = 0
while not stop_path.exists():
    holder = None
    try:
        lines = pathlib.Path("/proc/locks").read_text().splitlines()
    except OSError:
        lines = []
    for line in lines:
        parts = line.split()
        if len(parts) < 6 or parts[4] == "-1":
            continue
        try:
            if int(parts[5].rsplit(":", 1)[1]) == inode:
                holder = int(parts[4])
                break
        except ValueError:
            continue
    samples += 1
    if holder and holder != a_pid:
        try:
            status = pathlib.Path(f"/proc/{holder}/status").read_text().splitlines()
            uid = int(next(line for line in status if line.startswith("Uid:")).split()[1])
            command = pathlib.Path(f"/proc/{holder}/cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace").strip()
            starttime = int(pathlib.Path(f"/proc/{holder}/stat").read_text().split()[21])
        except (OSError, StopIteration, ValueError):
            time.sleep(0.02)
            continue
        if uid > 0 and "modelctl" in command and " rollback " in f" {command} ":
            observed = {
                "observed_b_lease": True,
                "pid": holder,
                "uid": uid,
                "starttime": starttime,
                "environment_inode": inode,
                "command": command,
                "observed_ns": time.time_ns(),
                "samples": samples,
            }
            break
    time.sleep(0.02)
payload = observed or {"observed_b_lease": False, "environment_inode": inode, "samples": samples}
out_path.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
os.chmod(out_path, 0o600)
if observed:
    print(f"OBSERVED_B_LEASE=1 pid={observed['pid']} uid={observed['uid']} environment_inode={inode} starttime={observed['starttime']}")
else:
    print(f"OBSERVED_B_LEASE=0 environment_inode={inode} samples={samples}")
PY
