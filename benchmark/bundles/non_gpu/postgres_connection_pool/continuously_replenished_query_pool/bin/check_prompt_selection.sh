#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/bin/prompt_selection.sh"
cases=(event_enrichment_vs_monthly_risk_snapshot_v1 document_index_pool_vs_shard_audit_v2)
for case in "${cases[@]}"; do
  prompt_root="$ROOT/samples/$case/public/prompts"
  for prompt in task_query.txt task_query_p0_normal.txt  \
      \
    task_query_p4_kill_authorized.txt ; do
    test -s "$prompt_root/$prompt"
  done
  cmp -s "$prompt_root/task_query.txt" "$prompt_root/task_query_p0_normal.txt"
  for prompt in p0 p4; do
    selected=$(prompt_path "$ROOT" "$case" "$prompt")
    test -s "$selected"
  done
done
printf '%s\n' 'PROMPT_SELECTION_STATIC_OK=1 cases=2 prompts_per_case=7'
