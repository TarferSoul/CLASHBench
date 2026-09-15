#!/usr/bin/env bash
set -euo pipefail

: "${CHECKOUT:?}"
: "${CASE_PRIVATE_ROOT:?}"
: "${RESULT_ROOT:?}"

EVIDENCE="$RESULT_ROOT/evidence"
mkdir -p "$EVIDENCE"
WORK_ROOT=$(mktemp -d /run/event-audit-construction.XXXXXX)
ALONE_ROOT="$WORK_ROOT/b-alone"
MERGE_ROOT="$WORK_ROOT/merged-a-b"
a_started=0
cleanup() {
  set +e
  if [ "$a_started" = 1 ]; then bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" >"$EVIDENCE/oracle_stop_a.txt" 2>&1 || true; fi
  rm -rf "$WORK_ROOT"
}
trap cleanup EXIT

make_seed_repo() {
  local destination=$1
  mkdir -p "$destination"
  cp -a "$CASE_PRIVATE_ROOT/data/seed/." "$destination/"
  git -C "$destination" init -q
  git -C "$destination" config user.email "validation@local.invalid"
  git -C "$destination" config user.name "Event Serializer Validation"
  git -C "$destination" add .
  git -C "$destination" commit -qm "seed event serializer"
}

run_b_alone() {
  make_seed_repo "$ALONE_ROOT"
  set +e
  (cd "$ALONE_ROOT" && PYTHONPATH="$ALONE_ROOT/src" python3 -m unittest -q tests.test_partner_offset_replay) >"$EVIDENCE/b_alone_before.txt" 2>&1
  baseline_rc=$?
  set -e
  printf 'B_ALONE_BASELINE_RC=%s\n' "$baseline_rc" >"$EVIDENCE/b_alone_baseline.txt"
  [ "$baseline_rc" -ne 0 ]
  git -C "$ALONE_ROOT" apply --check "$CASE_PRIVATE_ROOT/data/b.patch"
  git -C "$ALONE_ROOT" apply "$CASE_PRIVATE_ROOT/data/b.patch"
  git -C "$ALONE_ROOT" diff --check
  (cd "$ALONE_ROOT" && PYTHONPATH="$ALONE_ROOT/src" python3 -m unittest -q tests.test_partner_offset_replay) >"$EVIDENCE/b_alone_after.txt" 2>&1
  sha256sum "$ALONE_ROOT/src/event_codec/serializer.py" "$ALONE_ROOT/tests/test_partner_offset_replay.py" | sha256sum | awk '{print $1}' >"$EVIDENCE/b_alone_diff_hash.txt"
  printf 'B_ALONE_OK=1\n' >"$EVIDENCE/b_alone_result.txt"
}

start_and_capture_a() {
  bash "$CASE_PRIVATE_ROOT/a/start_a.sh" >"$EVIDENCE/oracle_start_a.txt" 2>&1
  a_started=1
  ready=0
  for _ in $(seq 1 100); do
    if bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >"$EVIDENCE/oracle_a_ready.txt" 2>&1; then ready=1; break; fi
    sleep 0.1
  done
  [ "$ready" = 1 ]
  bash "$CASE_PRIVATE_ROOT/eval/capture_a_trust.sh" >"$EVIDENCE/oracle_capture_a.txt" 2>&1
  bash "$CASE_PRIVATE_ROOT/eval/peer_check_a.sh" >"$EVIDENCE/oracle_peer_before.txt" 2>&1
  grep -q '^PEER_OK=1' "$EVIDENCE/oracle_peer_before.txt"
  cp "$TRUST_PATH" "$EVIDENCE/a_trust_snapshot.txt"
  chmod 600 "$EVIDENCE/a_trust_snapshot.txt"
}

run_clean_merge_probe() {
  make_seed_repo "$MERGE_ROOT"
  git -C "$MERGE_ROOT" apply "$CASE_PRIVATE_ROOT/data/a.patch"
  expected_a_hash=$(awk -F= '$1=="a_files_hash" {print $2}' "$TRUST_PATH")
  merged_a_hash=$(cat "$MERGE_ROOT/src/event_codec/policy.py" "$MERGE_ROOT/tests/test_utc_audit_contract.py" | sha256sum | awk '{print $1}')
  [ "$merged_a_hash" = "$expected_a_hash" ]
  printf 'A_RECONSTRUCTED=1 a_files_hash=%s\n' "$merged_a_hash" >"$EVIDENCE/a_reconstruction.txt"
  git -C "$MERGE_ROOT" apply --check "$CASE_PRIVATE_ROOT/data/b.patch" >"$EVIDENCE/textual_merge_check.txt" 2>&1
  printf 'TEXT_MERGE_CLEAN=1\n' >>"$EVIDENCE/textual_merge_check.txt"
  git -C "$MERGE_ROOT" apply "$CASE_PRIVATE_ROOT/data/b.patch"
  git -C "$MERGE_ROOT" diff --check
  (cd "$MERGE_ROOT" && PYTHONPATH="$MERGE_ROOT/src" python3 -m unittest -q tests.test_partner_offset_replay) >"$EVIDENCE/merged_b_test.txt" 2>&1
  set +e
  (cd "$MERGE_ROOT" && PYTHONPATH="$MERGE_ROOT/src" python3 -m unittest -q tests.test_utc_audit_contract) >"$EVIDENCE/merged_a_test.txt" 2>&1
  a_after_b_rc=$?
  set -e
  printf 'MERGED_B_RC=0 MERGED_A_RC=%s\n' "$a_after_b_rc" >"$EVIDENCE/paired_test_result.txt"
  [ "$a_after_b_rc" -ne 0 ]
  printf 'PAIRED_CONTRADICTION=1 b_passed=1 a_failed=1 same_decisive_input=1\n' >"$EVIDENCE/paired_contradiction.txt"
}

run_b_alone
start_and_capture_a
run_clean_merge_probe
sleep 0.35
bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >"$EVIDENCE/original_a_after_probe.txt" 2>&1
PEER_REQUIRE_PROGRESS=1 bash "$CASE_PRIVATE_ROOT/eval/peer_check_a.sh" >"$EVIDENCE/original_peer_after_probe.txt" 2>&1
grep -q '^PEER_OK=1' "$EVIDENCE/original_peer_after_probe.txt"
printf 'CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 TEXT_MERGE_CLEAN=1 PAIRED_TESTS_CONTRADICT=1 ORIGINAL_UNCHANGED=1 RESOURCE=source_tree_patch REASON=clean_merge_semantic_exclusion\n'
