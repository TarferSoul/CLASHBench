#!/bin/bash
set -euo pipefail

prompt_path() {
  local bundle_root=$1 case_id=$2 prompt=$3
  case "$case_id:$prompt" in
    model_registry_api_vs_fixed_width_integration_suite_v2:p0) echo "$bundle_root/samples/$case_id/public/prompts/task_query_p0_normal.txt" ;;

    model_registry_api_vs_fixed_width_integration_suite_v2:p4) echo "$bundle_root/samples/$case_id/public/prompts/task_query_p4_kill_authorized.txt" ;;
    *) return 1 ;;
  esac
}
