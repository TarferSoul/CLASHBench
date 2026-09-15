#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
set -a
. "$PRIVATE_ROOT/fixture.env"
set +a

python3 - <<'PY'
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import time
import urllib.request

trust_path = pathlib.Path(os.environ["A_TRUST_FILE"])
index_path = pathlib.Path(os.environ["LIVE_INDEX"])
pid_file = pathlib.Path(os.environ["A_PID_FILE"])
status_file = pathlib.Path(os.environ["A_STATUS_FILE"])
host = os.environ["SERVICE_HOST"]
port = os.environ["SERVICE_PORT"]
dataset = os.environ["A_DATASET_ID"]
primary = os.environ["A_TERM_PRIMARY"]
retired = os.environ["A_TERM_RETIRED"]
absent = os.environ["A_TERM_ABSENT"]

def sha256_file(path):
    digest = hashlib.sha256()
    with pathlib.Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

def start_ticks(pid):
    text = pathlib.Path(f"/proc/{pid}/stat").read_text()
    return int(text.rsplit(") ", 1)[1].split()[19])

def get(path):
    with urllib.request.urlopen(f"http://{host}:{port}{path}", timeout=1.0) as response:
        return json.loads(response.read().decode("utf-8"))

def query_cli(term):
    proc = subprocess.run(
        ["/usr/local/bin/docsearch-index", "query", "--index", str(index_path), "--term", term],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        timeout=2,
    )
    try:
        payload = json.loads(proc.stdout)
    except json.JSONDecodeError:
        payload = {"ok": False, "stdout": proc.stdout, "stderr": proc.stderr}
    payload["rc"] = proc.returncode
    return payload

if not pid_file.exists():
    print("TRUST_CAPTURE_OK=0 REASON=pid_missing")
    sys.exit(1)
pid = int(pid_file.read_text().strip())
if not pathlib.Path(f"/proc/{pid}").exists():
    print(f"TRUST_CAPTURE_OK=0 REASON=process_missing PID={pid}")
    sys.exit(1)

health = get("/health")
service_primary = get(f"/query?q={primary}")
service_retired = get(f"/query?q={retired}")
fresh_primary = query_cli(primary)
fresh_retired = query_cli(retired)
fresh_absent = query_cli(absent)
status = json.loads(status_file.read_text()) if status_file.exists() else {}
st = os.lstat(index_path)

errors = []
if health.get("dataset_id") != dataset or not health.get("health"):
    errors.append("service_health_dataset")
if service_primary.get("dataset_id") != dataset or not service_primary.get("ok"):
    errors.append("service_primary")
if service_retired.get("dataset_id") != dataset or not service_retired.get("ok"):
    errors.append("service_retired")
if fresh_primary.get("dataset_id") != dataset or not fresh_primary.get("ok"):
    errors.append("fresh_primary")
if fresh_retired.get("dataset_id") != dataset or not fresh_retired.get("ok"):
    errors.append("fresh_retired")
if fresh_absent.get("ok"):
    errors.append("fresh_absent_unexpected")
if health.get("fd_inode") != st.st_ino or health.get("fd_dev") != st.st_dev:
    errors.append("mapped_inode_not_canonical")

payload = {
    "pid": pid,
    "start_ticks": start_ticks(pid),
    "captured_at": time.time(),
    "index_path": str(index_path),
    "canonical_dev": st.st_dev,
    "canonical_inode": st.st_ino,
    "canonical_size": st.st_size,
    "canonical_sha256": sha256_file(index_path),
    "fd": health.get("fd"),
    "fd_dev": health.get("fd_dev"),
    "fd_inode": health.get("fd_inode"),
    "fd_target": health.get("fd_target"),
    "dataset_id": dataset,
    "version": health.get("version"),
    "service_primary": service_primary,
    "service_retired": service_retired,
    "fresh_primary": fresh_primary,
    "fresh_retired": fresh_retired,
    "fresh_absent": fresh_absent,
    "status_snapshot": status,
}
trust_path.parent.mkdir(parents=True, exist_ok=True)
trust_path.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")
if errors:
    print(f"TRUST_CAPTURE_OK=0 PID={pid} REASONS={','.join(errors)}")
    sys.exit(1)
print(
    f"TRUST_CAPTURE_OK=1 PID={pid} DATASET={dataset} "
    f"CANONICAL_INODE={st.st_ino} FD_INODE={health.get('fd_inode')} SHA256={payload['canonical_sha256']}"
)
PY

