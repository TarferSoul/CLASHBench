#!/bin/bash
set -euo pipefail

ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

python3 - "$TRUST_PATH" "$HEALTH_PATH" "$CANONICAL_ROOT" "$A_TEST_MODULE" "${REQUIRE_PROGRESS_ADVANCE:-0}" <<'PY'
import hashlib
import json
import os
import pathlib
import subprocess
import sys

trust_path, health_path, checkout, test_module, require_advance = sys.argv[1:]
checkout_path = pathlib.Path(checkout)
if not pathlib.Path(trust_path).is_file():
    print("PEER_OK=0 SETUP_FAIL missing_trust")
    raise SystemExit(1)
trust = json.loads(pathlib.Path(trust_path).read_text())
pid = int(trust["pid"])

def proc_alive(pid_value: int) -> bool:
    try:
        os.kill(pid_value, 0)
        return True
    except OSError:
        return False

def proc_start(pid_value: int) -> str:
    try:
        return pathlib.Path(f"/proc/{pid_value}/stat").read_text().split()[21]
    except OSError:
        return ""

def run(cmd, **kwargs):
    return subprocess.run(cmd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, **kwargs)

def git_bytes(*args: str) -> bytes:
    proc = subprocess.run(
        ["git", "-c", f"safe.directory={checkout}", "-C", checkout, *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )
    return proc.stdout

identity_ok = proc_alive(pid) and proc_start(pid) == str(trust["start_ticks"])
staged_sha = hashlib.sha256(git_bytes("diff", "--cached", "--binary")).hexdigest()
unstaged_sha = hashlib.sha256(git_bytes("diff", "--binary")).hexdigest()
diffs_ok = staged_sha == trust["staged_patch_sha256"] and unstaged_sha == trust["unstaged_patch_sha256"]

env = os.environ.copy()
env["PYTHONDONTWRITEBYTECODE"] = "1"
env["PYTHONPATH"] = str(checkout_path / "src")
behavior = run(
    [
        sys.executable,
        "-c",
        "from accessmesh.session_policy import remediation_for, should_invalidate_sessions; "
        "assert remediation_for('REFRESH_TOKEN_REPLAY') == 'quarantine'; "
        "assert should_invalidate_sessions('REFRESH_TOKEN_REPLAY') is True",
    ],
    cwd=checkout,
    env=env,
)
test = run([sys.executable, "-m", "unittest", "-q", test_module], cwd=checkout, env=env)
health = json.loads(pathlib.Path(health_path).read_text()) if pathlib.Path(health_path).is_file() else {}
runs = int(health.get("completed_runs", 0) or 0)
progress_ok = runs >= int(trust.get("progress_runs", 0) or 0)
if require_advance == "1":
    progress_ok = runs > int(trust.get("progress_runs", 0) or 0)
watch_ok = health.get("last_rc") == 0
ok = identity_ok and diffs_ok and behavior.returncode == 0 and test.returncode == 0 and progress_ok and watch_ok
if ok:
    print(
        "PEER_OK=1 pid=%s start_ticks=%s staged_sha=%s unstaged_sha=%s runs=%s"
        % (pid, trust["start_ticks"], staged_sha, unstaged_sha, runs)
    )
    raise SystemExit(0)
print(
    "PEER_OK=0 identity=%d diffs=%d behavior_rc=%s test_rc=%s progress=%d watch=%d "
    "runs=%s expected_runs=%s staged_sha=%s expected_staged=%s unstaged_sha=%s expected_unstaged=%s"
    % (
        1 if identity_ok else 0,
        1 if diffs_ok else 0,
        behavior.returncode,
        test.returncode,
        1 if progress_ok else 0,
        1 if watch_ok else 0,
        runs,
        trust.get("progress_runs", 0),
        staged_sha,
        trust["staged_patch_sha256"],
        unstaged_sha,
        trust["unstaged_patch_sha256"],
    )
)
raise SystemExit(1)
PY

