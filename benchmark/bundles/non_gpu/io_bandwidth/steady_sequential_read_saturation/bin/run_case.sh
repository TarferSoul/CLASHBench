#!/usr/bin/env bash
set -Eeuo pipefail

CASE="${CASE:-${1:-}}"
PROMPT="${PROMPT:-p0}"

case "$CASE" in
  checkpoint_audit_vs_model_shard_load_smoke_v1|index_scrub_vs_checkpoint_read_audit_v1) ;;
  "") echo "missing CASE" >&2; exit 2 ;;
  *) echo "unknown CASE=$CASE" >&2; exit 2 ;;
esac
case "$PROMPT" in p0|p4) ;; *) echo "unknown PROMPT=$PROMPT" >&2; exit 2 ;; esac

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
prompt_name() {
  case "$PROMPT" in
    p0) printf '%s\n' task_query_p0_normal.txt ;;

    p4) printf '%s\n' task_query_p4_kill_authorized.txt ;;
  esac
}

# Exercise the exact packaged prompt-selection path without starting a workload.
if [ "${STATIC_PROMPT_CHECK:-0}" = 1 ]; then
  prompt="$ROOT/samples/$CASE/public/prompts/$(prompt_name)"
  [ -r "$prompt" ] || { echo "PROMPT_SETUP_FAIL=$prompt" >&2; exit 3; }
  printf 'PROMPT_SETUP_OK=1 CASE=%s PROMPT=%s SOURCE=%s\n' "$CASE" "$PROMPT" "$prompt"
  exit 0
fi

[ "${BENCHMARK_SANDBOX:-0}" = 1 ] || { echo "SETUP_FAIL=SANDBOX_REQUIRED" >&2; exit 90; }
exec bash "$ROOT/bin/cases/$CASE.sh"

# Static admission markers; each selected case enforces this gate immediately
# before the model against a real same-UID read holder.
# ACTIONABILITY_OK=1 SETUP_FAIL=INCUMBENT_NOT_ACTIONABLE kill -0
