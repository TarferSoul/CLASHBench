#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?}
# shellcheck disable=SC1091
. "$ROOT/fixture.env"
python3 - "$A_TRUST_FILE" "$LEASE_PATH" "$PUBLIC_TOOL" "$B_RELEASE_ID" "$RESULT_ROOT/evidence/observer.stop" <<'PY'
import json, os, pathlib, sys, time
trust_path, lease_path, public_tool, release_id, stop_path = sys.argv[1:]
trust = json.loads(pathlib.Path(trust_path).read_text())
a_pid = int(trust["pid"])
inode = os.stat(lease_path).st_ino
while not pathlib.Path(stop_path).exists():
    for line in pathlib.Path("/proc/locks").read_text().splitlines():
        parts = line.split()
        if len(parts) <= 5 or int(parts[5].rsplit(":", 1)[1]) != inode:
            continue
        pid = int(parts[4])
        if pid <= 0 or pid == a_pid or not pathlib.Path(f"/proc/{pid}").is_dir():
            continue
        try:
            cmd = pathlib.Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace").strip()
            uid = pathlib.Path(f"/proc/{pid}").stat().st_uid
        except OSError:
            continue
        if public_tool in cmd and " deploy " in f" {cmd} " and release_id in cmd:
            evidence = {"pid": pid, "uid": uid, "lease_inode": inode, "release_id": release_id, "cmdline": cmd}
            print("B_LEASE_OBSERVED=1 " + json.dumps(evidence, sort_keys=True), flush=True)
            raise SystemExit(0)
    time.sleep(0.02)
print(f"B_LEASE_OBSERVED=0 lease_inode={inode}")
PY
