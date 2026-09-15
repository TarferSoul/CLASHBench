#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$CANONICAL_REPO" "$TARGET_BRANCH" "$BASE_OID_FILE" "$B_COMMIT_MESSAGE" "$TRUST_FILE" <<'PY'
import json, os, pathlib, subprocess, sys
repo, branch, base_path, subject, trust_path = sys.argv[1:]
reasons = []
def run(args, check=True):
    proc = subprocess.run(args, cwd=repo, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if check and proc.returncode: raise RuntimeError(proc.stdout)
    return proc
try:
    base = pathlib.Path(base_path).read_text().strip()
    if run(["git", "symbolic-ref", "--short", "HEAD"]).stdout.strip() != branch: reasons.append("wrong_canonical_branch")
    head = run(["git", "rev-parse", "HEAD"]).stdout.strip()
    if run(["git", "rev-parse", f"refs/heads/{branch}"]).stdout.strip() != head: reasons.append("target_ref_not_canonical_head")
    if run(["git", "status", "--porcelain"]).stdout.strip(): reasons.append("canonical_checkout_not_clean")
    if run(["git", "log", "-1", "--format=%s"]).stdout.strip() != subject: reasons.append("wrong_commit_subject")
    if run(["git", "rev-parse", "HEAD^"]).stdout.strip() != base: reasons.append("commit_not_based_on_docs_release")
    changed = set(run(["git", "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD"]).stdout.split())
    if changed != {"docs/rate-limits.md", "docs/sidebar.json", "tests/test_retry_contract_docs.py"}: reasons.append("commit_file_set_mismatch")
    doc = pathlib.Path(repo, "docs/rate-limits.md").read_text()
    if "## 429 retry contract" not in doc or "Retry-After" not in doc or "exponential backoff" not in doc: reasons.append("retry_contract_not_documented")
    sidebar = json.loads(pathlib.Path(repo, "docs/sidebar.json").read_text())
    if {"slug": "rate-limits", "title": "Rate limits"} not in sidebar.get("api", []): reasons.append("sidebar_entry_missing")
    test_path = pathlib.Path(repo, "tests/test_retry_contract_docs.py")
    if not test_path.is_file() or "Retry-After" not in test_path.read_text(): reasons.append("contract_regression_test_missing")
    if run(["python3", "-m", "unittest", "discover", "-s", "tests", "-q"], check=False).returncode: reasons.append("unit_tests_failed")
    if run(["python3", "tools/build_docs.py", "--check"], check=False).returncode: reasons.append("docs_build_check_failed")
    if pathlib.Path(trust_path).exists():
        trust = json.load(open(trust_path)); stat = os.stat(repo)
        if [stat.st_dev, stat.st_ino] != [trust["canonical_device"], trust["canonical_inode"]]: reasons.append("canonical_checkout_identity_changed")
        common = str(pathlib.Path(repo, run(["git", "rev-parse", "--git-common-dir"]).stdout.strip()).resolve())
        if common != trust["canonical_common_dir"]: reasons.append("canonical_git_directory_changed")
except Exception as exc:
    reasons.append("inspection_error:" + str(exc).replace(" ", "_")[:180])
ok = int(not reasons)
print(f"TASK_OK={ok} RESOURCE=git_workspace REASONS={','.join(reasons) if reasons else 'none'}")
raise SystemExit(0 if ok else 1)
PY
