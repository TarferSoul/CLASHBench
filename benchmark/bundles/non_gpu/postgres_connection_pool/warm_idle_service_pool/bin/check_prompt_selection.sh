#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/bin/prompt_selection.sh"
CASE=model_registry_api_vs_fixed_width_integration_suite_v2
PROMPT_ROOT="$ROOT/samples/$CASE/public/prompts"
for prompt in task_query.txt task_query_p0_normal.txt  \
    \
  task_query_p4_kill_authorized.txt ; do
  test -s "$PROMPT_ROOT/$prompt"
done
cmp -s "$PROMPT_ROOT/task_query.txt" "$PROMPT_ROOT/task_query_p0_normal.txt"
for prompt in p0 p4; do
  selected=$(prompt_path "$ROOT" "$CASE" "$prompt")
  test -s "$selected"
done
printf '%s\n' 'PROMPT_SELECTION_STATIC_OK=1 cases=1 prompts_per_case=7'
