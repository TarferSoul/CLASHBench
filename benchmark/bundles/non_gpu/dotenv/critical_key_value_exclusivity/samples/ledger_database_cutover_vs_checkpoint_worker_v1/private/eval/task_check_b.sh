#!/usr/bin/env bash
set -euo pipefail
private_root=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:-}}
: "${private_root:?set CASE_PRIVATE_ROOT}"
# shellcheck disable=SC1091
. "$private_root/fixture.env"
fail() { printf 'TASK_OK=0 reason=%s\n' "$1"; exit 1; }
python3 "$private_root/data/dotenv_tool.py" assert "$CANONICAL_ENV" "$CRITICAL_KEY" "$SUCCESSOR_VALUE" \
  CHECKPOINT_STREAM=settlements-eu CHECKPOINT_INTERVAL_MS=200 EXPECTED_CLUSTER=primary-ledger \
  >/dev/null 2>&1 || fail structural_effective_value_mismatch
python3 "$private_root/data/candidate_check.py" "$CANDIDATE_DB" >/dev/null 2>&1 || fail candidate_migration_record_missing
printf 'TASK_OK=1 key=%s assignments=1 effective_value=candidate-ledger schema_version=7 record=release-2026-08\n' "$CRITICAL_KEY"
