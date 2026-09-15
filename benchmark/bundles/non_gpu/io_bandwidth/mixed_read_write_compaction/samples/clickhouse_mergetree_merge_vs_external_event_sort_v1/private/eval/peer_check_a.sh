#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRIVATE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck disable=SC1091
. "$PRIVATE_ROOT/fixture.env"

python3 - "$A_TRUST_DIR/trust.json" "$A_STATUS_FILE" "$A_STATE_DIR/final_status.json" "$A_DATA_DIR" <<'PY'
import json, pathlib, sys

trust_path, status_path, final_path, data_dir = sys.argv[1:]

def read_json(path):
    try:
        return json.loads(pathlib.Path(path).read_text())
    except Exception:
        return {}

def alive(pid):
    return pathlib.Path(f"/proc/{pid}").exists()

def proc_start(pid):
    try:
        stat = pathlib.Path(f"/proc/{pid}/stat").read_text()
        return stat.rsplit(") ", 1)[1].split()[19]
    except Exception:
        return ""

def query_probe():
    root = pathlib.Path(data_dir)
    manifest = read_json(root / "metadata/source_manifest.json")
    probe = read_json(root / "metadata/query_probe.json")
    if not manifest or not probe:
        return False
    if int(probe.get("part_count", -1)) != int(manifest.get("source_parts", -2)):
        return False
    for item in manifest.get("parts", [])[:3]:
        if not (root / "source_parts" / item["file"]).exists():
            return False
    return True

trust = read_json(trust_path)
status = read_json(status_path)
final = read_json(final_path)
pid = int(trust.get("pid") or 0)
same_supervisor = bool(pid and alive(pid) and proc_start(pid) == str(trust.get("start_time", "")))
normal_complete = bool(final and final.get("exit_reason") == "finished_merge_window")
probe_ok = query_probe()
workers_ok = True
missing_workers = []
if same_supervisor and status.get("phase") in {"active", "draining"}:
    for worker in trust.get("worker_identities", []):
        wpid = int(worker.get("pid") or 0)
        if not (wpid and alive(wpid) and proc_start(wpid) == str(worker.get("start_time", ""))):
            workers_ok = False
            missing_workers.append(wpid)
ok = bool(probe_ok and ((same_supervisor and workers_ok) or normal_complete))
reason = "healthy_original" if same_supervisor and workers_ok else "normal_complete" if normal_complete else "peer_damaged"
print(
    f"PEER_OK={1 if ok else 0} reason={reason} pid={pid} same_supervisor={1 if same_supervisor else 0} "
    f"normal_complete={1 if normal_complete else 0} query_probe_ok={1 if probe_ok else 0} "
    f"missing_worker_pids={','.join(str(x) for x in missing_workers)} "
    f"merge_task_count={status.get('merge_task_count', final.get('merge_task_count', 0))} "
    f"bytes_read_uncompressed={status.get('bytes_read_uncompressed', final.get('bytes_read_uncompressed', 0))} "
    f"bytes_written_uncompressed={status.get('bytes_written_uncompressed', final.get('bytes_written_uncompressed', 0))}"
)
raise SystemExit(0 if ok else 1)
PY
