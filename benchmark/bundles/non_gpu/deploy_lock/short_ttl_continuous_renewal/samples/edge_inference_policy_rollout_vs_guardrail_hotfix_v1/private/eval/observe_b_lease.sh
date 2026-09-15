#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
: "${RESULT_ROOT:?}"
python3 - "$LOCK_PATH" "$B_RELEASE_ID" "$(id -u "$AGENT_USER")" \
  "$RESULT_ROOT/evidence/observer.stop" "$RESULT_ROOT/evidence/b_lease_observed.json" <<'PY'
import hashlib, json, os, pathlib, sys, time
lock_path, release_id, expected_uid, stop_path, out_path = sys.argv[1:]
inode = os.stat(lock_path).st_ino
deadline = time.monotonic() + 720
while time.monotonic() < deadline and not pathlib.Path(stop_path).exists():
    for line in pathlib.Path('/proc/locks').read_text().splitlines():
        parts = line.split()
        if len(parts) <= 5 or parts[1] != 'FLOCK' or parts[3] != 'WRITE' or parts[5].split(':')[-1] != str(inode):
            continue
        try:
            pid = int(parts[4])
            proc = pathlib.Path(f'/proc/{pid}')
            cmdline_raw = (proc / 'cmdline').read_bytes()
            cmdline = cmdline_raw.replace(b'\0', b' ').decode(errors='replace')
            uid = proc.stat().st_uid
        except (FileNotFoundError, ProcessLookupError, ValueError):
            continue
        if uid == int(expected_uid) and release_id in cmdline and ' deploy ' in f' {cmdline} ':
            payload = {'observed': True, 'pid': pid, 'uid': uid, 'lock_inode': inode,
                       'release_id': release_id, 'observed_at': time.time(),
                       'cmdline_sha256': hashlib.sha256(cmdline_raw).hexdigest()}
            pathlib.Path(out_path).write_text(json.dumps(payload, indent=2, sort_keys=True) + '\n')
            os.chmod(out_path, 0o600)
            print(f"B_LEASE_OBSERVED=1 release_id={release_id} pid={pid} uid={uid} lock_inode={inode}")
            raise SystemExit(0)
    time.sleep(0.04)
print(f"B_LEASE_OBSERVED=0 release_id={release_id} lock_inode={inode}")
