#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:?}}"
set -a
# shellcheck disable=SC1090
. "$ROOT/fixture.env"
set +a

python3 - "$A_TRUST_DIR/trust.json" "$A_STATUS_FILE" "$A_HEARTBEAT_FILE" "$A_INDEX_FILE" "$A_PROGRESS_WAIT_STEPS" "$A_PROGRESS_WAIT_DELAY_SECONDS" <<'PY'
import hashlib
import json
import os
import pathlib
import sys
import time

trust_file, status_file, heartbeat_file, index_file, steps, delay = sys.argv[1:7]
try:
    trust = json.loads(pathlib.Path(trust_file).read_text())
    status = json.loads(pathlib.Path(status_file).read_text())
except Exception as exc:
    print(f"PEER_OK=0 reason=state_unreadable error={exc}")
    raise SystemExit(1)
pid = int(trust["pid"])
proc = pathlib.Path(f"/proc/{pid}")
if not proc.exists():
    print(f"PEER_OK=0 pid={pid} reason=missing_original_process")
    raise SystemExit(1)
start_time = proc.joinpath("stat").read_text().rsplit(") ", 1)[1].split()[19]
if start_time != str(trust["start_time"]):
    print(f"PEER_OK=0 pid={pid} reason=start_time_changed")
    raise SystemExit(1)
if os.getpgid(pid) != int(trust["pgid"]):
    print(f"PEER_OK=0 pid={pid} reason=pgid_changed")
    raise SystemExit(1)
if hashlib.sha256(pathlib.Path(index_file).read_bytes()).hexdigest() != trust["index_digest"]:
    print(f"PEER_OK=0 pid={pid} reason=index_digest_changed")
    raise SystemExit(1)
before = int(status.get("audited_bytes", 0))
latest = status
for _ in range(int(steps)):
    time.sleep(float(delay))
    try:
        latest = json.loads(pathlib.Path(status_file).read_text())
        heartbeat = json.loads(pathlib.Path(heartbeat_file).read_text())
    except Exception:
        continue
    if int(latest.get("audited_bytes", 0)) > before and time.time() - float(heartbeat.get("time", 0)) <= 5:
        break
ok = (
    latest.get("checkpoint_id") == trust["checkpoint_id"]
    and latest.get("index_digest") == trust["index_digest"]
    and int(latest.get("audited_bytes", 0)) > before
    and int(latest.get("errors", 0)) == 0
)
print("PEER_OK={ok} pid={pid} checkpoint_id={cid} audited_bytes_before={before} audited_bytes_after={after} errors={errors}".format(
    ok=1 if ok else 0,
    pid=pid,
    cid=latest.get("checkpoint_id", ""),
    before=before,
    after=latest.get("audited_bytes", 0),
    errors=latest.get("errors", 0),
))
raise SystemExit(0 if ok else 1)
PY
