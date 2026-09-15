#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"

python3 - "$TRUST_ROOT/trust.json" "$A_RUNTIME_DIR/progress.json" <<'PY'
import hashlib, json, pathlib, sys
trust_path, progress_path = map(pathlib.Path, sys.argv[1:])
try:
    trust = json.loads(trust_path.read_text())
    pid = int(trust["pid"])
    proc = pathlib.Path(f"/proc/{pid}")
    if not proc.is_dir() or proc.stat().st_uid != int(trust["uid"]):
        raise ValueError("original_process_missing_or_uid_changed")
    raw = (proc / "stat").read_text()
    tail = raw[raw.rfind(")") + 2 :].split()
    if int(tail[2]) != int(trust["pgid"]) or int(tail[19]) != int(trust["start_ticks"]):
        raise ValueError("original_process_identity_changed")
    index_path = pathlib.Path(trust["index_path"])
    if hashlib.sha256(index_path.read_bytes()).hexdigest() != trust["index_sha256"]:
        raise ValueError("symbol_archive_index_changed")
    allocated = 0
    for item in trust["files"]:
        path = pathlib.Path(item["path"])
        stat = path.stat()
        if (stat.st_dev, stat.st_ino, stat.st_size, stat.st_blocks * 512) != (
            item["device"], item["inode"], item["size"], item["allocated_bytes"]
        ):
            raise ValueError("symbol_bundle_identity_changed")
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != item["sha256"]:
            raise ValueError("symbol_bundle_checksum_changed")
        allocated += stat.st_blocks * 512
    progress = json.loads(progress_path.read_text())
    if progress.get("state") != "uploading_verified_symbols" or int(progress.get("upload_offset", 0)) < int(trust["progress_upload_offset"]):
        raise ValueError("symbol_upload_progress_regressed")
    print(f"PEER_OK=1 pid={pid} uid={trust['uid']} start_ticks={trust['start_ticks']} files={len(trust['files'])} allocated_bytes={allocated} progress_passes={progress['passes']} upload_offset={progress['upload_offset']}")
except Exception as exc:
    reason = str(exc).replace("Traceback", "trace").replace("FileNotFoundError", "missing_file")
    print(f"PEER_OK=0 reason=peer_check_failed:{reason}")
    raise SystemExit(1)
PY
