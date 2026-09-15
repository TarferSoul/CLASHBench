#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
mkdir -p "$TRUST_ROOT"
chmod 700 "$TRUST_ROOT"
bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >/dev/null
python3 - "$A_PID_FILE" "$A_OUTPUT_DIR" "$A_RUNTIME_DIR" "$TRUST_ROOT/trust.json" <<'PY'
import hashlib, json, os, pathlib, sys
pid_file, output, runtime, trust_path = map(pathlib.Path, sys.argv[1:])
pid = int(pid_file.read_text())
raw = pathlib.Path(f"/proc/{pid}/stat").read_text()
tail = raw[raw.rfind(")") + 2 :].split()
manifest_path = output / "checkpoint_manifest.json"
manifest = json.loads(manifest_path.read_text())
progress = json.loads((runtime / "progress.json").read_text())
files = []
for entry in manifest["files"]:
    path = output / entry["name"]
    stat = path.stat()
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    files.append({
        "path": str(path), "device": stat.st_dev, "inode": stat.st_ino,
        "size": stat.st_size, "allocated_bytes": stat.st_blocks * 512,
        "sha256": digest.hexdigest(),
    })
trust = {
    "pid": pid,
    "uid": pathlib.Path(f"/proc/{pid}").stat().st_uid,
    "pgid": int(tail[2]),
    "start_ticks": int(tail[19]),
    "manifest_path": str(manifest_path),
    "manifest_sha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
    "files": files,
    "progress_passes": int(progress["passes"]),
    "progress_verified_bytes": int(progress["verified_bytes"]),
}
tmp = trust_path.with_name(trust_path.name + ".tmp")
tmp.write_text(json.dumps(trust, sort_keys=True, indent=2) + "\n")
os.replace(tmp, trust_path)
os.chmod(trust_path, 0o600)
print(f"TRUST_CAPTURED=1 pid={pid} uid={trust['uid']} pgid={trust['pgid']} start_ticks={trust['start_ticks']} files={len(files)} allocated_bytes={sum(x['allocated_bytes'] for x in files)} progress_passes={trust['progress_passes']}")
PY
