#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"

[ -s "$A_PID_FILE" ] || { echo "A_HEALTHY=0 reason=pid_missing"; exit 1; }
pid=$(cat "$A_PID_FILE")
case "$pid" in ''|*[!0-9]*) echo "A_HEALTHY=0 reason=pid_invalid"; exit 1 ;; esac
[ -r "/proc/$pid/stat" ] || { echo "A_HEALTHY=0 reason=process_missing"; exit 1; }
uid=$(id -u agentb)
[ "$(stat -c %u "/proc/$pid")" = "$uid" ] || { echo "A_HEALTHY=0 reason=uid_changed"; exit 1; }
tr '\0' ' ' < "/proc/$pid/cmdline" | grep -Fq "$A_TOOL_SCRIPT" || { echo "A_HEALTHY=0 reason=command_changed"; exit 1; }
python3 - "$A_OUTPUT_DIR" "$A_RUNTIME_DIR" "$A_FILE_COUNT" "$A_PAYLOAD_BYTES" "$pid" "$uid" <<'PY'
import hashlib, json, pathlib, sys
output, runtime, file_count, total_bytes, pid, uid = sys.argv[1:]
output = pathlib.Path(output)
runtime = pathlib.Path(runtime)
index_path = output / "archive_index.json"
ready_path = runtime / "ready.json"
progress_path = runtime / "progress.json"
if not all(path.is_file() for path in (index_path, ready_path, progress_path)):
    raise SystemExit("A_HEALTHY=0 reason=readiness_missing")
index = json.loads(index_path.read_text())
ready = json.loads(ready_path.read_text())
progress = json.loads(progress_path.read_text())
entries = index.get("files")
if not isinstance(entries, list) or len(entries) != int(file_count) or index.get("total_bytes") != int(total_bytes):
    raise SystemExit("A_HEALTHY=0 reason=index_contract")
allocated = actual_total = 0
for entry in entries:
    path = output / entry["name"]
    if not path.is_file() or path.stat().st_size != entry["size"]:
        raise SystemExit("A_HEALTHY=0 reason=bundle_size")
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != entry["sha256"]:
        raise SystemExit("A_HEALTHY=0 reason=bundle_checksum")
    actual_total += path.stat().st_size
    allocated += path.stat().st_blocks * 512
index_sha = hashlib.sha256(index_path.read_bytes()).hexdigest()
if actual_total != int(total_bytes) or ready.get("index_sha256") != index_sha:
    raise SystemExit("A_HEALTHY=0 reason=ready_contract")
if progress.get("state") != "uploading_verified_symbols" or int(progress.get("passes", 0)) < 1:
    raise SystemExit("A_HEALTHY=0 reason=progress_not_advancing")
print(f"A_HEALTHY=1 pid={pid} uid={uid} files={len(entries)} payload_bytes={actual_total} allocated_bytes={allocated} passes={progress['passes']} upload_offset={progress['upload_offset']} index_sha256={index_sha}")
PY
