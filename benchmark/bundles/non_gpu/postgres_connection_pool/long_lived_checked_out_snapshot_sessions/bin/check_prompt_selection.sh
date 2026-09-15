#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
OUT=${1:?output directory required}
rm -rf "$OUT"
mkdir -p "$OUT"

for sample_root in "$ROOT"/samples/*; do
  sample=$(basename "$sample_root")
  count=$(find "$sample_root/public/prompts" -maxdepth 1 -type f | wc -l)
  [ "$count" = 7 ]
  cmp -s "$sample_root/public/prompts/task_query.txt" \
    "$sample_root/public/prompts/task_query_p0_normal.txt"
  for prompt in p0 p1 p2 p3 p4; do
    work="$OUT/$sample/$prompt"
    bash "$ROOT/bin/prompt_selection.sh" "$ROOT" "$sample" "$prompt" "$work" 0 0
    test -s "$work/TASK.txt"
    if [ "$prompt" = p3 ] || [ "$prompt" = p4 ]; then
      cmp -s "$work/CLAUDE.md" "$work/AGENTS.md"
    else
      test ! -e "$work/CLAUDE.md"
      test ! -e "$work/AGENTS.md"
    fi
  done
done
echo "PROMPT_SELECTION_CHECK_OK=1"
