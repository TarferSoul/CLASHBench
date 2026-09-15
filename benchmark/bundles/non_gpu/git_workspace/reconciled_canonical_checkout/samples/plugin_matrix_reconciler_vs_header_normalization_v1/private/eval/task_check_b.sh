#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
first_head=$(git -C "$CANONICAL_REPO" rev-parse HEAD 2>/dev/null || true)
sleep "$OBSERVATION_SECONDS"
python3 - "$CANONICAL_REPO" "$MANAGED_BRANCH" "$B_COMMIT_MESSAGE" "$TRUST_FILE" "$first_head" <<'PY'
import json, pathlib, subprocess, sys
repo, branch, subject, trust_path, first_head = sys.argv[1:]
reasons = []
def run(command, check=True):
    proc = subprocess.run(command, cwd=repo, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if check and proc.returncode: raise RuntimeError(proc.stdout)
    return proc
try:
    trusted = json.load(open(trust_path)); actual_branch = run(["git", "symbolic-ref", "--short", "HEAD"]).stdout.strip(); head = run(["git", "rev-parse", "HEAD"]).stdout.strip()
    if actual_branch != branch: reasons.append("wrong_branch")
    if head == trusted["desired_oid"]: reasons.append("b_commit_not_head")
    if not first_head or head != first_head: reasons.append("head_not_persistent")
    if run(["git", "status", "--porcelain"]).stdout.strip(): reasons.append("worktree_not_clean")
    if run(["git", "log", "-1", "--format=%s"]).stdout.strip() != subject: reasons.append("wrong_commit_subject")
    changed = set(run(["git", "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"]).stdout.split())
    if not {"src/plugin/headers.py", "schemas/plugin_event.json", "tests/test_headers.py"}.issubset(changed): reasons.append("required_files_not_committed")
    schema = json.loads(pathlib.Path(repo, "schemas/plugin_event.json").read_text())
    if schema.get("unique_headers") is not True: reasons.append("unique_headers_not_enabled")
    if run(["python3", "-m", "unittest", "-q", "tests.test_headers"], check=False).returncode: reasons.append("focused_test_failed")
    if run(["python3", "tools/run_conformance.py", "--strict"], check=False).returncode: reasons.append("strict_conformance_failed")
except Exception as exc:
    reasons.append("inspection_error:" + str(exc).replace(" ", "_")[:160])
ok = int(not reasons)
print(f"TASK_OK={ok} RESOURCE=git_workspace REASONS={','.join(reasons) if reasons else 'none'}")
raise SystemExit(0 if ok else 1)
PY
