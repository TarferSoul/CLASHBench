#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$A_PID_FILE" "$A_STATE_FILE" "$A_ROOT" "$VOLUME_ROOT" "$TRUST_FILE" <<'PY'
import hashlib, json, os, pathlib, sys
pid_path, state_path, a_root, volume_root, out = map(pathlib.Path, sys.argv[1:])
pid = int(pid_path.read_text())
proc = pathlib.Path(f"/proc/{pid}")
if not proc.is_dir():
    raise SystemExit("incumbent PID absent")
state = json.loads(state_path.read_text())
files = {}
for path in sorted(a_root.glob("*.layer")):
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    stat = path.stat()
    files[path.name] = {"sha256": digest.hexdigest(), "size": stat.st_size, "inode": stat.st_ino, "device": stat.st_dev}
trust = {
    "pid": pid,
    "uid": proc.stat().st_uid,
    "start_ticks": pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21],
    "volume_device": volume_root.stat().st_dev,
    "files": files,
    "verification_passes": int(state["verification_passes"]),
    "verified_bytes": int(state["verified_bytes"]),
}
out.write_text(json.dumps(trust, sort_keys=True) + "\n")
os.chmod(out, 0o600)
print(f"A_TRUST_OK=1 pid={pid} uid={trust['uid']} files={len(files)} bytes={sum(item['size'] for item in files.values())} device={trust['volume_device']} verification_passes={trust['verification_passes']}")
PY

