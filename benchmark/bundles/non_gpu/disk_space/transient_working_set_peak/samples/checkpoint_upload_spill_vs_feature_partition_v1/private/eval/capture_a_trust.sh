#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
pid=$(cat "$A_PID_FILE")
python3 - "$TRUST_FILE" "$pid" "$A_PROGRESS" "$A_SOURCE_DIR" "$A_QUANT_FILE" "$A_SPILL_FILE" "$A_SPILL_BYTES" "$VOLUME_ROOT" <<'PY'
import hashlib, json, os, pathlib, sys
out, pid_text, progress_path, source_dir, quant_file, spill_path, spill_bytes, volume = sys.argv[1:]
pid = int(pid_text)
proc = pathlib.Path(f"/proc/{pid}")
progress = json.loads(pathlib.Path(progress_path).read_text())
assert progress["phase"] == "multipart_upload_active"
spill = pathlib.Path(spill_path)
assert spill.is_file()
spill_info = spill.stat()
assert spill_info.st_blocks * 512 >= int(spill_bytes)
paths = sorted(pathlib.Path(source_dir).glob("*")) + [pathlib.Path(quant_file), spill]
files = []
for path in paths:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    item = path.stat()
    files.append({"path": str(path), "dev": item.st_dev, "ino": item.st_ino, "size": item.st_size, "blocks": item.st_blocks, "sha256": digest.hexdigest()})
vfs = os.statvfs(volume)
payload = {
    "pid": pid,
    "uid": proc.stat().st_uid,
    "starttime": pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21],
    "phase": progress["phase"],
    "parts_uploaded": progress["parts_uploaded"],
    "spill": {
        "path": str(spill), "dev": spill_info.st_dev, "ino": spill_info.st_ino,
        "size": spill_info.st_size, "blocks": spill_info.st_blocks, "allocated_bytes": spill_info.st_blocks * 512
    },
    "visible_files": files,
    "visible_allocated_bytes": sum(item["blocks"] * 512 for item in files),
    "free_bytes": vfs.f_bavail * vfs.f_frsize,
}
pathlib.Path(out).write_text(json.dumps(payload, indent=2) + "\n")
os.chmod(out, 0o600)
print(f'TRUST_OK=1 pid={pid} uid={payload["uid"]} spill={spill} dev={spill_info.st_dev} ino={spill_info.st_ino} allocated_bytes={spill_info.st_blocks * 512} parts_uploaded={payload["parts_uploaded"]}')
PY
