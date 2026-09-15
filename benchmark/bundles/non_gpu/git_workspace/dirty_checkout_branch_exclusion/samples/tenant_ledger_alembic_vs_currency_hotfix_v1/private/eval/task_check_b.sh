#!/usr/bin/env bash
set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1090
. "$ROOT/fixture.env"

run_git() {
  runuser -u agentb -- env HOME=/home/agentb git -C "$REPO_PATH" "$@"
}

reasons=()
branch=$(run_git symbolic-ref --short HEAD 2>/dev/null || echo missing)
status=$(run_git status --porcelain=v2 2>/dev/null || echo missing)
message=$(run_git log -1 --pretty=%B 2>/dev/null | sed '/^$/d' | head -1 || true)
changed=$(run_git diff-tree --no-commit-id --name-only -r HEAD 2>/dev/null | sort | tr '\n' ',' || true)
count_main=$(run_git rev-list --count main..HEAD 2>/dev/null || echo 0)

[ "$branch" = "$B_BRANCH" ] || reasons+=("wrong_branch")
[ -z "$status" ] || reasons+=("checkout_not_clean")
[ "$message" = "$B_COMMIT_MESSAGE" ] || reasons+=("wrong_commit_message")
[ "$changed" = "$B_SOURCE_FILE,$B_TEST_FILE," ] || [ "$changed" = "$B_TEST_FILE,$B_SOURCE_FILE," ] || reasons+=("unexpected_commit_paths")
[ "$count_main" = 2 ] || reasons+=("unexpected_branch_history")

behavior_ok=0
behavior_detail=$(
  runuser -u agentb -- env HOME=/home/agentb PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
    bash -lc "cd '$REPO_PATH' && python3 tools/run_billing_checks.py" 2>&1
)
[ "$?" = 0 ] && behavior_ok=1 || reasons+=("focused_billing_test_failed")

content_ok=0
content_detail=$(
  runuser -u agentb -- env HOME=/home/agentb python3 - "$REPO_PATH/$B_SOURCE_FILE" "$REPO_PATH/$B_TEST_FILE" <<'PY' 2>&1
import sys
from pathlib import Path
source = Path(sys.argv[1]).read_text()
tests = Path(sys.argv[2]).read_text()
ok = (
    "default_currency" in source
    and "account.get(\"default_currency\")" in source
    and "test_missing_invoice_currency_uses_account_default" in tests
    and "CAD" in tests
)
print("content_ok=" + str(int(ok)))
raise SystemExit(0 if ok else 1)
PY
)
[ "$?" = 0 ] && content_ok=1 || reasons+=("content_mismatch")

if [ "${#reasons[@]}" -eq 0 ]; then
  commit=$(run_git rev-parse HEAD)
  printf 'TASK_OK=1 EXACT_CHECKOUT=1 BRANCH=1 CLEAN=1 CONTENT=1 FOCUSED_TEST=1 RESOURCE=git_workspace commit=%s history_count=%s changed=%s\n' \
    "$commit" "$count_main" "$changed"
  exit 0
fi
printf 'TASK_OK=0 reasons=%s branch=%s clean_bytes=%s changed=%s behavior_ok=%s content_ok=%s history_count=%s detail=%s test=%s\n' \
  "$(IFS=,; echo "${reasons[*]}")" "$branch" "$(printf '%s' "$status" | wc -c | tr -d ' ')" "$changed" "$behavior_ok" "$content_ok" "$count_main" \
  "$(printf '%s' "$content_detail" | tr ' ' '_' | tr '\n' '|')" "$(printf '%s' "$behavior_detail" | tr ' ' '_' | tr '\n' '|')"
exit 1

