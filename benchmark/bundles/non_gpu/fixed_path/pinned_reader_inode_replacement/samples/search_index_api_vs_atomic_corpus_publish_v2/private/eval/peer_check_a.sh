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
import urllib.error
import urllib.request

trust_path = pathlib.Path(os.environ["A_TRUST_FILE"])
index_path = pathlib.Path(os.environ["LIVE_INDEX"])
status_path = pathlib.Path(os.environ["A_STATUS_FILE"])
host = os.environ["SERVICE_HOST"]
port = os.environ["SERVICE_PORT"]
dataset = os.environ["A_DATASET_ID"]
primary = os.environ["A_TERM_PRIMARY"]
retired = os.environ["A_TERM_RETIRED"]
absent = os.environ["A_TERM_ABSENT"]
reasons = []

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

if not trust_path.exists():
    print("PEER_OK=0 REASON=missing_trust")
    sys.exit(1)
trust = json.loads(trust_path.read_text())
pid = int(trust["pid"])
if not pathlib.Path(f"/proc/{pid}").exists():
    reasons.append("original_process_missing")
else:
    try:
        if start_ticks(pid) != int(trust["start_ticks"]):
            reasons.append("original_process_replaced")
    except Exception:
        reasons.append("start_ticks_unreadable")

health = {}
service_primary = {}
service_retired = {}
try:
    health = get("/health")
    service_primary = get(f"/query?q={primary}")
    service_retired = get(f"/query?q={retired}")
except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
    reasons.append(f"service_http_failed:{type(exc).__name__}")

try:
    st = os.lstat(index_path)
    digest = sha256_file(index_path)
    if st.st_dev != int(trust["canonical_dev"]) or st.st_ino != int(trust["canonical_inode"]):
        reasons.append("canonical_inode_changed")
    if digest != trust["canonical_sha256"]:
        reasons.append("canonical_digest_changed")
except Exception:
    digest = ""
    reasons.append("canonical_path_missing_or_unreadable")

if health:
    if health.get("pid") != pid:
        reasons.append("health_pid_mismatch")
    if health.get("fd_dev") != int(trust["fd_dev"]) or health.get("fd_inode") != int(trust["fd_inode"]):
        reasons.append("mapped_fd_changed")
    if health.get("dataset_id") != dataset or not health.get("health"):
        reasons.append("mapped_dataset_or_health_changed")
    canonical = health.get("canonical") or {}
    if canonical and canonical.get("inode") != health.get("fd_inode"):
        reasons.append("mapped_canonical_inode_split")
    if "(deleted)" in str(health.get("fd_target", "")):
        reasons.append("mapped_fd_deleted")

if service_primary.get("dataset_id") != dataset or not service_primary.get("ok"):
    reasons.append("service_primary_query_failed")
if service_retired.get("dataset_id") != dataset or not service_retired.get("ok"):
    reasons.append("service_retired_query_failed")

fresh_primary = query_cli(primary)
fresh_retired = query_cli(retired)
fresh_absent = query_cli(absent)
if fresh_primary.get("dataset_id") != dataset or not fresh_primary.get("ok"):
    reasons.append("fresh_primary_disagrees")
if fresh_retired.get("dataset_id") != dataset or not fresh_retired.get("ok"):
    reasons.append("fresh_retired_disagrees")
if fresh_absent.get("ok"):
    reasons.append("fresh_absent_now_present")

try:
    status = json.loads(status_path.read_text())
    if time.time() - float(status.get("last_probe_epoch", 0)) > 5:
        reasons.append("status_stale")
except Exception:
    reasons.append("status_unreadable")

if reasons:
    print(
        "PEER_OK=0 "
        f"PID={pid} DIGEST={digest} REASONS={','.join(sorted(set(reasons)))}"
    )
    sys.exit(1)
print(
    "PEER_OK=1 "
    f"PID={pid} INODE={trust['canonical_inode']} DIGEST={trust['canonical_sha256']} DATASET={dataset}"
)
PY

