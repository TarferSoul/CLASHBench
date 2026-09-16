#!/usr/bin/env bash
set -euo pipefail

if [ "${BENCHMARK_SANDBOX:-0}" != 1 ]; then
  echo "SETUP_FAIL=SANDBOX_REQUIRED" >&2
  exit 90
fi

CASE=${CASE:-${1:-}}
MODE=${MODE:-run}
PROMPT=${PROMPT:-p0}
HARNESS=${HARNESS:-codex}
if [ -n "${BUNDLE_SOURCE:-}" ]; then
  BUNDLE_ROOT=$(cd "$BUNDLE_SOURCE" && pwd)
  SCRIPT_DIR="$BUNDLE_ROOT/bin"
else
  SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  BUNDLE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
fi

case "$CASE" in
  pg_basebackup_vs_migration_readiness_v1|ci_cache_replication_vs_metadata_probe_v1) ;;
  *) echo "unknown CASE=$CASE" >&2; exit 2 ;;
esac
case "$MODE" in oracle|run|prompt_check) ;;
  *) echo "unknown MODE=$MODE" >&2; exit 2 ;;
esac
case "$PROMPT" in p0|p4) ;;
  *) echo "unknown PROMPT=$PROMPT" >&2; exit 2 ;;
esac
case "$HARNESS" in claude|opencode|codex) ;;
  *) echo "unknown HARNESS=$HARNESS" >&2; exit 2 ;;
esac

CASE_ROOT="$BUNDLE_ROOT/samples/$CASE"
# The delegated case runners fail closed with ACTIONABILITY_OK=1 or
# SETUP_FAIL=INCUMBENT_NOT_ACTIONABLE after a same-UID runuser kill -0 probe.
prompt_file() {
  case "$PROMPT" in
    p0) printf '%s\n' "$CASE_ROOT/public/prompts/task_query_p0_normal.txt" ;;

    p4) printf '%s\n' "$CASE_ROOT/public/prompts/task_query_p4_kill_authorized.txt" ;;
  esac
}

# Exercise the same packaged prompt-selection path used by the runtime before
# any Sandbox submission. This catches nested-path mistakes locally.
if [ "$MODE" = prompt_check ]; then
  for path in "$CASE_ROOT/public/prompts/task_query.txt" \
      "$CASE_ROOT/public/prompts/task_query_p0_normal.txt" \
       \
       \
       \
      "$CASE_ROOT/public/prompts/task_query_p4_kill_authorized.txt" \
      ; do
    test -f "$path" || { echo "PROMPT_SETUP_FAIL=missing:$path" >&2; exit 3; }
  done
  cmp -s "$CASE_ROOT/public/prompts/task_query.txt" "$CASE_ROOT/public/prompts/task_query_p0_normal.txt"
  cmp -s "$CASE_ROOT/public/prompts/task_query_p0_normal.txt" "$CASE_ROOT/public/prompts/task_query_p4_kill_authorized.txt"
  printf 'PROMPT_SELECTION_OK=1 case=%s selected=%s\n' "$CASE" "$(prompt_file)"
  exit 0
fi

case "$CASE" in
  pg_basebackup_vs_migration_readiness_v1)
    exec env BUNDLE_SOURCE="$BUNDLE_ROOT" CASE="$CASE" MODE="$MODE" PROMPT="$PROMPT" HARNESS="$HARNESS" \
      "$SCRIPT_DIR/run_case_pg.sh"
    ;;
  ci_cache_replication_vs_metadata_probe_v1)
    exec env BUNDLE_SOURCE="$BUNDLE_ROOT" CASE="$CASE" MODE="$MODE" PROMPT="$PROMPT" HARNESS="$HARNESS" \
      "$SCRIPT_DIR/run_case_ci.sh"
    ;;
esac
