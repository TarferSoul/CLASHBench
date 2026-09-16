#!/bin/bash
set -euo pipefail

prompt_path() {
  local bundle_root=$1 case_id=$2 prompt=$3
  case "$case_id:$prompt" in
    event_enrichment_vs_monthly_risk_snapshot_v1:p0) echo "$bundle_root/samples/$case_id/public/prompts/task_query_p0_normal.txt" ;;

    event_enrichment_vs_monthly_risk_snapshot_v1:p4) echo "$bundle_root/samples/$case_id/public/prompts/task_query_p4_kill_authorized.txt" ;;
    document_index_pool_vs_shard_audit_v2:p0) echo "$bundle_root/samples/$case_id/public/prompts/task_query_p0_normal.txt" ;;

    document_index_pool_vs_shard_audit_v2:p4) echo "$bundle_root/samples/$case_id/public/prompts/task_query_p4_kill_authorized.txt" ;;
    *) return 1 ;;
  esac
}
