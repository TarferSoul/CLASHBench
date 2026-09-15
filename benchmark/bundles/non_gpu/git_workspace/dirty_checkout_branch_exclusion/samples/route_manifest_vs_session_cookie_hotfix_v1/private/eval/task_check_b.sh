#!/usr/bin/env bash
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/fixture.env"

python3 - "$CANONICAL_REPO" "$FIXTURE_STATE" "$B_BRANCH" "$B_COMMIT_MESSAGE" <<'PY'
import json
import os
import pathlib
import pwd
import subprocess
import sys

repo = pathlib.Path(sys.argv[1]).resolve()
fixture = json.loads(pathlib.Path(sys.argv[2]).read_text())
branch, expected_message = sys.argv[3:]
expected_files = [
    "web/src/auth/__tests__/sessionCookie.spec.ts",
    "web/src/auth/sessionCookie.ts",
    "web/src/router/sessionRedirect.ts",
]

def git(*args, check=False):
    command = ["git", "-C", str(repo), *args]
    try:
        owner = pwd.getpwuid(repo.stat().st_uid).pw_name
    except OSError:
        owner = "root"
    if os.geteuid() == 0 and owner != "root":
        command = ["runuser", "-u", owner, "--", *command]
    return subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check)

checks = {}
checks["exact_checkout"] = str(repo) == "/srv/app/repo"
checks["branch"] = git("symbolic-ref", "--short", "HEAD").stdout.strip() == branch
head = git("rev-parse", "HEAD").stdout.strip()
parent = git("rev-parse", "HEAD^").stdout.strip() if head else ""
checks["new_commit"] = bool(head) and head != fixture["maintenance_oid"]
checks["parent"] = parent == fixture["maintenance_oid"]
checks["target_ref"] = git("rev-parse", f"refs/heads/{branch}").stdout.strip() == head
checks["feature_ref_unchanged"] = git("rev-parse", "refs/heads/feature/dashboard-route-consolidation").stdout.strip() == fixture["feature_oid"]
checks["message"] = git("show", "-s", "--format=%s", "HEAD").stdout.strip() == expected_message
checks["clean"] = git("status", "--porcelain=v2", "-z").stdout == ""
changed = sorted(line for line in git("diff", "--name-only", fixture["maintenance_oid"], "HEAD").stdout.splitlines() if line)
checks["expected_files_only"] = changed == expected_files
try:
    owner = pwd.getpwuid(repo.stat().st_uid).pw_name
    content_test = subprocess.run(
        ["runuser", "-u", owner, "--", "python3", "tools/run_web_auth_checks.py"],
        cwd=repo,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
except Exception as exc:
    content_test = subprocess.CompletedProcess([], 99, "", f"focused check unavailable: {type(exc).__name__}: {exc}")
checks["focused_test"] = content_test.returncode == 0
ok = all(checks.values())
fields = " ".join(f"{name.upper()}={int(value)}" for name, value in checks.items())
print(f"TASK_OK={int(ok)} {fields} RESOURCE=git_workspace commit={head or 'missing'}")
if content_test.stdout.strip():
    print(content_test.stdout.rstrip())
PY
