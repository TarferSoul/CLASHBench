#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
: "${RESULT_ROOT:?RESULT_ROOT must name the root-only result directory}"

EVIDENCE="$RESULT_ROOT/evidence/construction"
mkdir -p "$EVIDENCE"
a_started=0

cleanup() {
  if [ "$a_started" = 1 ]; then
    bash "$ROOT/a/stop_a.sh" > "$EVIDENCE/cleanup_stop_a.txt" 2>&1 || true
  fi
}
trap cleanup EXIT

base_head=$(python3 - "$FIXTURE_STATE" <<'PY'
import json
import pathlib
import sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["base_head"])
PY
)

# Control: the exact ordinary edit, test, add, and commit workflow succeeds.
python3 "$ROOT/data/b_workflow.py" execute \
  --repo "$CANONICAL_REPO" --message "$B_MESSAGE" \
  > "$EVIDENCE/b_alone_execute.txt" 2>&1
python3 "$ROOT/data/b_workflow.py" verify \
  --repo "$CANONICAL_REPO" --state "$FIXTURE_STATE" --message "$B_MESSAGE" \
  > "$EVIDENCE/b_alone_verify.txt" 2>&1
b_alone_head=$(runuser -u agentb -- git -C "$CANONICAL_REPO" rev-parse HEAD)
printf 'base_head=%s\nb_alone_head=%s\n' "$base_head" "$b_alone_head" > "$EVIDENCE/b_alone_refs.txt"

# Restore the identical fixture while retaining no B ref or index publication.
runuser -u agentb -- git -C "$CANONICAL_REPO" reset --hard "$base_head" \
  > "$EVIDENCE/reset_after_b_alone.txt" 2>&1
runuser -u agentb -- git -C "$CANONICAL_REPO" clean -fd \
  >> "$EVIDENCE/reset_after_b_alone.txt" 2>&1
[ "$(runuser -u agentb -- git -C "$CANONICAL_REPO" rev-parse HEAD)" = "$base_head" ]
[ -z "$(runuser -u agentb -- git -C "$CANONICAL_REPO" status --porcelain)" ]

# Start the real renormalization transaction and capture identity and index state.
bash "$ROOT/a/start_a.sh" > "$EVIDENCE/start_a.txt" 2>&1
a_started=1
bash "$ROOT/a/status_a.sh" > "$EVIDENCE/a_status_ready.txt"
bash "$ROOT/eval/capture_a_trust.sh" > "$EVIDENCE/capture_a_trust.txt"
bash "$ROOT/eval/peer_check_a.sh" > "$EVIDENCE/peer_baseline.txt"
grep -q '^PEER_OK=1 ' "$EVIDENCE/peer_baseline.txt"
cp "$A_TRUST_FILE" "$EVIDENCE/a_trust_snapshot.json"

# Replay the exact B workflow. Its ordinary git add must fail on A's live index lock.
set +e
python3 "$ROOT/data/b_workflow.py" execute \
  --repo "$CANONICAL_REPO" --message "$B_MESSAGE" \
  > "$EVIDENCE/b_with_a.stdout" 2> "$EVIDENCE/b_with_a.stderr"
b_with_a_rc=$?
set -e
printf '%s\n' "$b_with_a_rc" > "$EVIDENCE/b_with_a.rc"
[ "$b_with_a_rc" -ne 0 ]
grep -Eqi 'index\.lock|Unable to create.*index.lock' "$EVIDENCE/b_with_a.stderr"
grep -Eqi 'File exists|another git process' "$EVIDENCE/b_with_a.stderr"
[ "$(runuser -u agentb -- git -C "$CANONICAL_REPO" rev-parse HEAD)" = "$base_head" ]
[ "$(runuser -u agentb -- git -C "$CANONICAL_REPO" branch --show-current)" = "$B_BRANCH" ]

# B's worktree edits may exist, but no B ref or index entry may be published.
python3 "$ROOT/data/transaction_state.py" compare-live \
  --repo "$CANONICAL_REPO" --runtime "$A_RUNTIME_ROOT" --trust "$A_TRUST_FILE" \
  --wait-seconds 12 > "$EVIDENCE/a_live_after_b.json"
bash "$ROOT/eval/peer_check_a.sh" > "$EVIDENCE/peer_after_b.txt"
grep -q '^PEER_OK=1 ' "$EVIDENCE/peer_after_b.txt"
runuser -u agentb -- git -C "$CANONICAL_REPO" status --porcelain=v2 --branch \
  > "$EVIDENCE/status_after_b_refusal.txt"

# The original transaction must finish normally and validate its complete candidate index.
python3 "$ROOT/data/transaction_state.py" wait-complete \
  --repo "$CANONICAL_REPO" --runtime "$A_RUNTIME_ROOT" --trust "$A_TRUST_FILE" \
  --expected-shards "$CATALOG_SHARDS" --records-per-shard "$CATALOG_RECORDS_PER_SHARD" \
  --wait-seconds "$A_COMPLETE_TIMEOUT_SECONDS" > "$EVIDENCE/a_completion.json"
cp "$A_PROGRESS_FILE" "$EVIDENCE/a_progress_final.json"
cp "$A_VALIDATION_FILE" "$EVIDENCE/a_validation_final.json"
cat "$A_RUNTIME_ROOT/prepare.log" > "$EVIDENCE/a_prepare.txt"
cat "$A_RUNTIME_ROOT/validation.log" > "$EVIDENCE/a_validation.txt"
bash "$ROOT/eval/peer_check_a.sh" > "$EVIDENCE/peer_after_completion.txt"
grep -q '^PEER_OK=1 ' "$EVIDENCE/peer_after_completion.txt"

bash "$ROOT/a/stop_a.sh" > "$EVIDENCE/stop_a.txt"
a_started=0
trap - EXIT

echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 LOCK_SPECIFIC_FAILURE=1 B_REFS_UNCHANGED=1 B_INDEX_ENTRIES_UNCHANGED=1 A_PROGRESS_CONTINUED=1 A_COMPLETED=1 A_CATALOG_VALID=1 RESOURCE=git_workspace REASON=live_index_transaction_blocks_ordinary_porcelain"

