#!/usr/bin/env bash
set -euo pipefail
PRIVATE_CASE=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
# shellcheck disable=SC1091
. "$PRIVATE_CASE/fixture.env"
: "${TRUST_FILE:?}"
python3 - "$TRUST_FILE" "$LEDGER_PATH" "$B_VISIBLE_INPUT" "$B_RECEIPT_PATH" "$B_SESSION_ID" <<'PY'
import hashlib, json, os, pathlib, subprocess, sys
trust_path, ledger_path, input_path, receipt_path, session_id = sys.argv[1:]
def canonical(value): return json.dumps(value, sort_keys=True, separators=(",", ":"))
try:
    trust = json.loads(pathlib.Path(trust_path).read_text())
    receipt = json.loads(pathlib.Path(receipt_path).read_text())
    expected = [json.loads(line) for line in pathlib.Path(input_path).read_text().splitlines() if line]
    ledger_stat = os.stat(ledger_path)
    assert (ledger_stat.st_dev, ledger_stat.st_ino) == (trust["ledger_dev"], trust["ledger_inode"])
    assert ledger_stat.st_uid == 0 and (ledger_stat.st_mode & 0o077) == 0
    collector_pid = trust["collector_pid"]
    assert pathlib.Path(f"/proc/{collector_pid}").exists()
    probe = r'''import json, os, pathlib, sys
rows=[]
for fd in pathlib.Path(f"/proc/{sys.argv[1]}/fd").iterdir():
    try: stat=os.stat(fd)
    except OSError: continue
    rows.append([stat.st_dev, stat.st_ino])
print(json.dumps(rows))'''
    fd_rows = json.loads(subprocess.check_output(["runuser", "-u", "agentb", "--", "python3", "-c", probe, str(collector_pid)], text=True))
    descriptor_match = [ledger_stat.st_dev, ledger_stat.st_ino] in fd_rows
    assert descriptor_match
    frames = [json.loads(line) for line in pathlib.Path(ledger_path).read_text().splitlines() if line]
    selected = [frame for frame in frames if frame.get("session_id") == session_id]
    begins = [frame for frame in selected if frame.get("frame") == "BEGIN"]
    data = sorted((frame for frame in selected if frame.get("frame") == "DATA"), key=lambda frame: frame["index"])
    commits = [frame for frame in selected if frame.get("frame") == "COMMIT"]
    aborts = [frame for frame in selected if frame.get("frame") == "ABORT"]
    assert len(begins) == 1 and len(commits) == 1 and not aborts
    assert [frame["payload"] for frame in data] == expected
    assert all(frame["payload_sha256"] == hashlib.sha256(canonical(frame["payload"]).encode()).hexdigest() for frame in data)
    offsets = [frame["offset"] for frame in data]
    digests = [frame["payload_sha256"] for frame in data]
    transaction_digest = hashlib.sha256("".join(digests).encode()).hexdigest()
    assert receipt["status"] == "COMMITTED" and receipt["session_id"] == session_id
    assert receipt["record_count"] == len(expected) and receipt["durable_offsets"] == offsets
    assert receipt["commit_offset"] == commits[0]["offset"]
    assert receipt["transaction_sha256"] == transaction_digest == commits[0]["transaction_sha256"]
    print(f"TASK_OK=1 session={session_id} records={len(expected)} first_offset={offsets[0]} commit_offset={commits[0]['offset']} transaction_sha256={transaction_digest}")
except Exception as error:
    print(f"TASK_OK=0 reason={type(error).__name__} detail={str(error)[:160]!r}")
PY
