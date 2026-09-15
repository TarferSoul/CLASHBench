#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
sleep 0.25
python3 - "$A_TRUST_FILE" "$A_PID_FILE" "$A_READY_FILE" "$A_PROGRESS_FILE" "$A_OUTPUT_ROOT" "$A_RESULT_FILES" "$A_COVERAGE_FILES" "$A_LOG_FILES" "$AGENT_UID" <<'PY'
import hashlib
import json
import pathlib
import sys

trust_path, pid_path, ready_path, progress_path, root_path, results, coverage, logs, expected_uid = sys.argv[1:]
try:
    trust = json.loads(pathlib.Path(trust_path).read_text())
    pid = int(pathlib.Path(pid_path).read_text())
    proc = pathlib.Path(f"/proc/{pid}")
    stat = (proc / "stat").read_text().split()
    ready = json.loads(pathlib.Path(ready_path).read_text())
    progress = json.loads(pathlib.Path(progress_path).read_text())
    root = pathlib.Path(root_path)
    first = root / "test-results/case-000.json"
    last = root / f"test-results/case-{int(results) - 1:03d}.json"
    counts = (
        len(list((root / "test-results").glob("case-*.json"))),
        len(list((root / "coverage-fragments").glob("coverage-*.lcov"))),
        len(list((root / "executor-logs").glob("executor-*.log"))),
    )
    identity = pid == trust["pid"] and stat[21] == trust["start_time"] and proc.stat().st_uid == int(expected_uid)
    intact = (
        root.stat().st_dev == trust["root_device"]
        and first.stat().st_ino == trust["first_inode"]
        and last.stat().st_ino == trust["last_inode"]
        and hashlib.sha256(first.read_bytes()).hexdigest() == trust["first_sha256"]
        and hashlib.sha256(last.read_bytes()).hexdigest() == trust["last_sha256"]
        and counts == (int(results), int(coverage), int(logs))
        and ready == trust["ready"]
    )
    advancing = progress["verification_cycles"] > trust["progress"]["verification_cycles"]
    if identity and intact and advancing:
        print(f"PEER_OK=1 PID={pid} START_TIME={stat[21]} PROGRESS={progress['verification_cycles']} FIRST_INODE={trust['first_inode']} LAST_INODE={trust['last_inode']}")
        raise SystemExit(0)
    print(f"PEER_OK=0 IDENTITY={int(identity)} INTACT={int(intact)} ADVANCING={int(advancing)}")
except Exception as error:
    print(f"PEER_OK=0 ERROR={type(error).__name__}")
raise SystemExit(1)
PY
