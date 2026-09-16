#!/bin/bash
set -euo pipefail
select_prompt_file() {
  local bundle=$1 case_id=$2 prompt=$3
  case "$prompt" in
    p0) printf '%s\n' "$bundle/samples/$case_id/public/prompts/task_query_p0_normal.txt" ;;

    p4) printf '%s\n' "$bundle/samples/$case_id/public/prompts/task_query_p4_kill_authorized.txt" ;;
    *) return 2 ;;
  esac
}
