#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
set +e
python3 - "$TRUST_FILE" "$A_PROGRESS" <<'PY'
import hashlib, json, os, pathlib, sys, time
trust_path, progress_path = sys.argv[1:]
issues = []
try:
    trust = json.loads(pathlib.Path(trust_path).read_text())
except Exception as exc:
    print(f"PEER_OK=0 reason=trust_unreadable detail={type(exc).__name__}")
    raise SystemExit(1)
pid = trust["pid"]
proc = pathlib.Path(f"/proc/{pid}")
if not proc.is_dir():
    issues.append("original_pid_missing")
else:
    if proc.stat().st_uid != trust["uid"]:
        issues.append("uid_changed")
    try:
        if pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21] != trust["starttime"]:
            issues.append("starttime_changed")
    except OSError:
        issues.append("proc_stat_missing")
try:
    progress_file = pathlib.Path(progress_path)
    progress = json.loads(progress_file.read_text())
    if progress.get("phase") != "multipart_upload_active":
        issues.append("phase_changed")
    if progress.get("parts_uploaded", -1) < trust["parts_uploaded"]:
        issues.append("upload_progress_regressed")
    if time.time() - progress_file.stat().st_mtime >= 4:
        issues.append("upload_progress_stale")
except Exception:
    issues.append("progress_invalid")
spill = trust["spill"]
spill_path = pathlib.Path(spill["path"])
try:
    info = spill_path.stat()
    if (info.st_dev, info.st_ino, info.st_size, info.st_blocks) != (
        spill["dev"], spill["ino"], spill["size"], spill["blocks"]
    ):
        issues.append("spill_identity_or_allocation_changed")
except OSError:
    issues.append("active_spill_missing")
for expected in trust["visible_files"]:
    path = pathlib.Path(expected["path"])
    if not path.is_file():
        issues.append("visible_working_file_missing")
        continue
    info = path.stat()
    if (info.st_dev, info.st_ino, info.st_size, info.st_blocks) != (
        expected["dev"], expected["ino"], expected["size"], expected["blocks"]
    ):
        issues.append("visible_working_file_changed")
        continue
    # The active multipart spill is intentionally rewritten as upload parts
    # arrive; its trusted identity and allocation are checked above, while
    # immutable source and quantization files still require content stability.
    if str(path) != spill["path"]:
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        if digest != expected["sha256"]:
            issues.append("visible_working_content_changed")
if issues:
    print("PEER_OK=0 reason=" + ",".join(sorted(set(issues))) + f" pid={pid}")
    raise SystemExit(1)
print(f'PEER_OK=1 pid={pid} starttime={trust["starttime"]} phase=multipart_upload_active spill={spill_path} dev={spill["dev"]} ino={spill["ino"]} allocated_bytes={spill["allocated_bytes"]}')
PY
rc=$?
set -e
exit "$rc"
