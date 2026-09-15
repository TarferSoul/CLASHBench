#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

CASE_PRIVATE_ROOT="$ROOT" bash "$ROOT/a/status_a.sh" >/dev/null
python3 - "$A_STATE_FILE" "$A_TRUST_FILE" "$A_DESIRED_BUNDLE" "$A_DESIRED_MANIFEST" "$A_SIGNING_KEY" "$FIXED_TRUST_PATH" <<'PY'
import hashlib, json, os, pathlib, subprocess, sys, time

state_path, trust_path, bundle_path, manifest_path, key_path, target_path = map(pathlib.Path, sys.argv[1:])
state = json.loads(state_path.read_text())
pid = int(state["pid"])
proc_fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
pgid = int(subprocess.check_output(["ps", "-o", "pgid=", "-p", str(pid)], text=True).strip())
target = state.get("target", {})
trust = {
    "captured_at": time.time(),
    "pid": pid,
    "proc_start_ticks": proc_fields[21],
    "pgid": pgid,
    "state_start_ticks": state.get("start_ticks", ""),
    "desired_sha256": state.get("desired_sha256", ""),
    "manifest_sha256": state.get("manifest_sha256", ""),
    "desired_source_file_sha256": hashlib.sha256(bundle_path.read_bytes()).hexdigest(),
    "manifest_file_sha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
    "signing_key_sha256": hashlib.sha256(key_path.read_bytes()).hexdigest(),
    "target_inode": target.get("inode", ""),
    "target_sha256": target.get("sha256", ""),
    "target_mode": target.get("mode", ""),
    "target_uid": target.get("uid"),
    "target_gid": target.get("gid"),
    "reconcile_count": int(state.get("reconcile_count") or 0),
    "inotify_event_count": int(state.get("inotify_event_count") or 0),
    "consumer_ok": bool(state.get("consumer_ok")),
    "source_verified": bool(state.get("source_verified")),
    "fixed_path": str(target_path),
}
trust_path.parent.mkdir(parents=True, exist_ok=True)
tmp = trust_path.with_suffix(".tmp")
tmp.write_text(json.dumps(trust, indent=2, sort_keys=True) + "\n")
os.chmod(tmp, 0o600)
tmp.replace(trust_path)
print(
    "TRUST_CAPTURED=1 "
    f"pid={pid} pgid={pgid} desired_sha256={trust['desired_sha256']} "
    f"manifest_sha256={trust['manifest_sha256']} target_sha256={trust['target_sha256']} "
    f"mode={trust['target_mode']} owner={trust['target_uid']}:{trust['target_gid']} "
    f"reconcile_count={trust['reconcile_count']} consumer_ok=1"
)
PY
