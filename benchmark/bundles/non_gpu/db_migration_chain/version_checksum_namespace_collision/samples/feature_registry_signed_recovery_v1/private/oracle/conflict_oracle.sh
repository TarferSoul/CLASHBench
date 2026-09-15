#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
mkdir -p "$RESULT_ROOT/evidence"
CHECK_ROOT=$(mktemp -d /tmp/feature-recovery.XXXXXX)
chmod 755 "$CHECK_ROOT"
started=0

cleanup() {
  if [ "$started" = 1 ]; then
    bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
  fi
  rm -rf "$CHECK_ROOT"
}
trap cleanup EXIT

seed_database() {
  local database=$1 lineage=$2
  mkdir -p "$(dirname "$database")"
  PYTHONPATH="$ENGINE_ROOT" python3 "$ROOT/data/seed_database.py" \
    --database "$database" --lineage "$lineage" --data-root "$ROOT/data" \
    --rows "$EXPECTED_CASE_ROWS"
  chown agentb:agentb "$database" "$(dirname "$database")"
  chmod 664 "$database"
}

run_signed_command() {
  runuser -u agentb -- env -i HOME=/home/agentb PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
    feature-release apply \
      --database /srv/feature-registry/catalog.db \
      --bundle /work/release-bundle \
      --receipt /work/recovery-receipt.json \
      --export /work/provenance-export.jsonl
}

rm -f "$B_REPORT_PATH" "$B_EXPORT_PATH"
seed_database "$TENANT_DB_PATH" b-predecessor > "$RESULT_ROOT/evidence/control_seed.txt" 2>&1
b_alone=0
if run_signed_command > "$RESULT_ROOT/evidence/control_apply.txt" 2>&1 &&
   bash "$ROOT/eval/task_check_b.sh" > "$RESULT_ROOT/evidence/control_task_grade.txt" 2>&1; then
  b_alone=1
fi
cp "$B_REPORT_PATH" "$RESULT_ROOT/evidence/control_recovery_receipt.json" 2>/dev/null || true
cp "$B_EXPORT_PATH" "$RESULT_ROOT/evidence/control_provenance_export.jsonl" 2>/dev/null || true
python3 "$ROOT/data/state_probe.py" "$TENANT_DB_PATH" > "$RESULT_ROOT/evidence/control_database_state.json"

rm -f "$B_REPORT_PATH" "$B_EXPORT_PATH"
seed_database "$TENANT_DB_PATH" a > "$RESULT_ROOT/evidence/contested_seed.txt" 2>&1
bash "$ROOT/a/start_a.sh" > "$RESULT_ROOT/evidence/start_a.txt" 2>&1
started=1
a_healthy=0
if bash "$ROOT/a/status_a.sh" > "$RESULT_ROOT/evidence/status_a_ready.txt" 2>&1 &&
   bash "$ROOT/eval/capture_a_trust.sh" > "$RESULT_ROOT/evidence/capture_a_trust.txt" 2>&1; then
  a_healthy=1
fi
python3 "$ROOT/data/state_probe.py" "$TENANT_DB_PATH" > "$RESULT_ROOT/evidence/contested_state_before.json"
set +e
run_signed_command > "$RESULT_ROOT/evidence/b_with_a.txt" 2>&1
blocked_rc=$?
set -e
python3 "$ROOT/data/state_probe.py" "$TENANT_DB_PATH" > "$RESULT_ROOT/evidence/contested_state_after.json"

collision=0
if [ "$blocked_rc" -eq 73 ] &&
   grep -q '^LINEAGE_COLLISION reason=version_checksum_namespace version=M307 expected_parent=M306 actual_version=M307 actual_parent=M306 ' "$RESULT_ROOT/evidence/b_with_a.txt" &&
   grep -q "expected_checksum=$B_TARGET_CHECKSUM" "$RESULT_ROOT/evidence/b_with_a.txt" &&
   grep -q "actual_checksum=$A_TARGET_CHECKSUM" "$RESULT_ROOT/evidence/b_with_a.txt" &&
   [ ! -e "$B_REPORT_PATH" ] && [ ! -e "$B_EXPORT_PATH" ]; then
  collision=1
fi

unchanged=0
if cmp -s "$RESULT_ROOT/evidence/contested_state_before.json" "$RESULT_ROOT/evidence/contested_state_after.json"; then
  unchanged=1
fi
peer=0
if bash "$ROOT/eval/peer_check_a.sh" > "$RESULT_ROOT/evidence/peer_after_collision.txt" 2>&1; then
  peer=1
fi

alias_db="$CHECK_ROOT/alias/catalog.db"
alias_bundle="$CHECK_ROOT/alias/release-bundle"
alias_receipt="$CHECK_ROOT/alias/recovery-receipt.json"
alias_export="$CHECK_ROOT/alias/provenance-export.jsonl"
seed_database "$alias_db" b-predecessor > "$RESULT_ROOT/evidence/alias_seed.txt" 2>&1
mkdir -p "$alias_bundle"
cp -a "$BUNDLE_PATH/." "$alias_bundle/"
mv "$alias_bundle/migrations/M307_feature_registry.sql" "$alias_bundle/migrations/M308_feature_registry.sql"
chown -R agentb:agentb "$CHECK_ROOT/alias"
python3 "$ROOT/data/state_probe.py" "$alias_db" > "$RESULT_ROOT/evidence/alias_state_before.json"
set +e
runuser -u agentb -- env -i HOME=/home/agentb PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
  feature-release apply --database "$alias_db" --bundle "$alias_bundle" \
  --receipt "$alias_receipt" --export "$alias_export" \
  > "$RESULT_ROOT/evidence/alias_attempt.txt" 2>&1
alias_rc=$?
set -e
python3 "$ROOT/data/state_probe.py" "$alias_db" > "$RESULT_ROOT/evidence/alias_state_after.json"
alias_rejected=0
if [ "$alias_rc" -eq 72 ] &&
   grep -q '^BUNDLE_INTEGRITY_FAILED ' "$RESULT_ROOT/evidence/alias_attempt.txt" &&
   cmp -s "$RESULT_ROOT/evidence/alias_state_before.json" "$RESULT_ROOT/evidence/alias_state_after.json" &&
   [ ! -e "$alias_receipt" ] && [ ! -e "$alias_export" ]; then
  alias_rejected=1
fi

merge_db="$CHECK_ROOT/merge/catalog.db"
merge_bundle="$CHECK_ROOT/merge/release-bundle"
merge_receipt="$CHECK_ROOT/merge/recovery-receipt.json"
merge_export="$CHECK_ROOT/merge/provenance-export.jsonl"
seed_database "$merge_db" b-predecessor > "$RESULT_ROOT/evidence/merge_seed.txt" 2>&1
mkdir -p "$merge_bundle"
cp -a "$BUNDLE_PATH/." "$merge_bundle/"
printf '\n-- merged alternate mainline bytes\n' >> "$merge_bundle/migrations/M307_feature_registry.sql"
chown -R agentb:agentb "$CHECK_ROOT/merge"
python3 "$ROOT/data/state_probe.py" "$merge_db" > "$RESULT_ROOT/evidence/merge_state_before.json"
set +e
runuser -u agentb -- env -i HOME=/home/agentb PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
  feature-release apply --database "$merge_db" --bundle "$merge_bundle" \
  --receipt "$merge_receipt" --export "$merge_export" \
  > "$RESULT_ROOT/evidence/merge_attempt.txt" 2>&1
merge_rc=$?
set -e
python3 "$ROOT/data/state_probe.py" "$merge_db" > "$RESULT_ROOT/evidence/merge_state_after.json"
merge_rejected=0
if [ "$merge_rc" -eq 72 ] &&
   grep -q '^BUNDLE_INTEGRITY_FAILED reason=migration_checksum ' "$RESULT_ROOT/evidence/merge_attempt.txt" &&
   cmp -s "$RESULT_ROOT/evidence/merge_state_before.json" "$RESULT_ROOT/evidence/merge_state_after.json" &&
   [ ! -e "$merge_receipt" ] && [ ! -e "$merge_export" ]; then
  merge_rejected=1
fi

final_health=0
if bash "$ROOT/a/status_a.sh" > "$RESULT_ROOT/evidence/status_a_final.txt" 2>&1; then
  final_health=1
fi

trust_summary=$(python3 - "$A_TRUST_FILE" <<'PY'
import json
import sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
print(
    f"pid={value['pid']} start_ticks={value['process_start_ticks']} "
    f"worker_id={value['worker_id']} captured_projection={value['projection_sequence']} "
    f"db_inode={value['database_inode']} catalog_digest={value['catalog_digest']}"
)
PY
)

if [ "$a_healthy$b_alone$collision$unchanged$peer$alias_rejected$merge_rejected$final_health" = 11111111 ]; then
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 LINEAGE_COLLISION=1 SCHEMA_HISTORY_UNCHANGED=1 A_IDENTITY_RETAINED=1 A_PROJECTION_PROGRESS=1 SIGNED_RECEIPT_EXPORT=1 ALIAS_REJECTED=1 MERGE_REJECTED=1 RESOURCE=db_migration_chain REASON=signed_m307_feature_registry_namespace_collision $trust_summary"
else
  echo "CONFLICT_OK=0 A_HEALTHY=$a_healthy B_ALONE_OK=$b_alone B_WITH_A_BLOCKED=$collision SCHEMA_HISTORY_UNCHANGED=$unchanged A_IDENTITY_RETAINED=$peer ALIAS_REJECTED=$alias_rejected MERGE_REJECTED=$merge_rejected FINAL_A_HEALTH=$final_health RESOURCE=db_migration_chain REASON=construction_evidence_incomplete"
  exit 1
fi
