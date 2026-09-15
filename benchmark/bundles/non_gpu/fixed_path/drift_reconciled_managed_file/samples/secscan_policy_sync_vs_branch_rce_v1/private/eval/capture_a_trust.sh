#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

bash "$ROOT/a/status_a.sh" >/dev/null
python3 - "$A_PID_FILE" "$A_STATE_FILE" "$A_DESIRED_BUNDLE" "$A_DESIRED_MANIFEST" "$A_SIGNING_KEY" "$FIXED_POLICY_PATH" "$TRUST_FILE" <<'PY'
import hashlib, json, os, pathlib, stat, sys, time
pid_file, state_file, desired_bundle, desired_manifest, signing_key, target_path, trust_file = map(pathlib.Path, sys.argv[1:])
pid = int(pid_file.read_text().strip())
parts = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
state = json.loads(state_file.read_text())
def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
info = target_path.lstat()
trust = {
    "pid": pid,
    "start_ticks": parts[21],
    "pgid": parts[4],
    "captured_at": time.time(),
    "desired_digest": digest(desired_bundle),
    "manifest_digest": digest(desired_manifest),
    "signing_key_digest": digest(signing_key),
    "state": state,
    "target": {
        "path": str(target_path),
        "mode": f"{stat.S_IMODE(info.st_mode):04o}",
        "uid": info.st_uid,
        "gid": info.st_gid,
        "regular": stat.S_ISREG(info.st_mode) and not target_path.is_symlink(),
        "sha256": digest(target_path),
        "inode": info.st_ino,
        "device": info.st_dev,
    },
}
trust_file.parent.mkdir(parents=True, exist_ok=True)
tmp = trust_file.with_suffix(".tmp")
tmp.write_text(json.dumps(trust, indent=2, sort_keys=True) + "\n")
os.chmod(tmp, 0o600)
tmp.replace(trust_file)
print(
    "A_TRUST_CAPTURED=1 "
    f"pid={pid} start_ticks={trust['start_ticks']} digest={trust['target']['sha256']} "
    f"repairs={state.get('repair_count', 0)} canary_ok={int(bool(state.get('canary_ok')))}"
)
PY
