#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1090
. "$ROOT/fixture.env"

run_git() {
  runuser -u agentb -- env HOME=/home/agentb git -C "$REPO_PATH" "$@"
}

pid=$(cat "$A_PID_FILE")
starttime=$(awk '{print $22}' "/proc/$pid/stat")
head_ref=$(run_git symbolic-ref --short HEAD)
head_oid=$(run_git rev-parse HEAD)
index_tree=$(run_git write-tree)
hash_staged=$(run_git diff --cached --binary | sha256sum | awk '{print $1}')
hash_unstaged=$(run_git diff --binary | sha256sum | awk '{print $1}')
status_hash=$(run_git status --porcelain=v2 | sha256sum | awk '{print $1}')
generation=$(cat "$A_STATE_DIR/generation")
focused_out=$(
  runuser -u agentb -- env HOME=/home/agentb PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
    python3 "$REPO_PATH/tools/check_tenant_ledger_roundtrip.py" --repo "$REPO_PATH" --once --state-dir "$A_STATE_DIR/trust_once"
)
focused_rc=0
focused_input_sha256=$(
  {
    run_git show ":$A_STAGED_MIGRATION_PATH"
    printf '\n'
    run_git show ":$A_STAGED_SCHEMA_PATH"
    printf '\n'
    runuser -u agentb -- env HOME=/home/agentb cat "$REPO_PATH/$A_UNSTAGED_PATH"
  } | sha256sum | awk '{print $1}'
)

mkdir -p "$(dirname "$A_TRUST_FILE")"
cat >"$A_TRUST_FILE" <<EOF
A_PID=$pid
A_STARTTIME=$starttime
A_HEAD_REF=$head_ref
A_HEAD_OID=$head_oid
A_INDEX_TREE=$index_tree
A_STAGED_DIFF_SHA256=$hash_staged
A_UNSTAGED_DIFF_SHA256=$hash_unstaged
A_STATUS_SHA256=$status_hash
A_FOCUSED_RC=$focused_rc
A_FOCUSED_INPUT_SHA256=$focused_input_sha256
A_GENERATION=$generation
A_STAGED_SCHEMA_PATH=$A_STAGED_SCHEMA_PATH
A_STAGED_MIGRATION_PATH=$A_STAGED_MIGRATION_PATH
A_UNSTAGED_PATH=$A_UNSTAGED_PATH
EOF
chmod 600 "$A_TRUST_FILE"
printf 'A_TRUST_OK=1 pid=%s starttime=%s head_ref=%s head_oid=%s index_tree=%s staged_diff_sha256=%s unstaged_diff_sha256=%s focused_input_sha256=%s focused_test_rc=%s generation=%s\n' \
  "$pid" "$starttime" "$head_ref" "$head_oid" "$index_tree" "$hash_staged" "$hash_unstaged" "$focused_input_sha256" "$focused_rc" "$generation"
printf '%s\n' "$focused_out" >&2

