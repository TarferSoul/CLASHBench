#!/usr/bin/env bash
set -euo pipefail

# The packaged dispatcher keeps each sample's private fixture self-contained.
CASE="${CASE:-${1:-}}"
PROMPT="${PROMPT:-p0}"
HARNESS="${HARNESS:-codex}"
MODE="${MODE:-run}"

if [[ "${STATIC_PROMPT_CHECK:-0}" == 1 ]]; then
  case "$CASE" in
    trainer_checkpoint_vs_recovery_bundle_v1|feature_snapshot_vs_index_pack_v1) ;;
    *) echo "unknown CASE=$CASE" >&2; exit 2 ;;
  esac
  case "$PROMPT" in p0|p4) ;; *) echo "unknown PROMPT=$PROMPT" >&2; exit 2 ;; esac
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
  case "$PROMPT" in
    p0) name=task_query_p0_normal.txt;; 

    p4) name=task_query_p4_kill_authorized.txt;;
  esac
  prompt="$root/samples/$CASE/public/prompts/$name"
  [[ -r "$prompt" ]] || { echo "PROMPT_SETUP_FAIL=$prompt" >&2; exit 3; }
  printf 'PROMPT_SETUP_OK=1 CASE=%s PROMPT=%s SOURCE=%s\n' "$CASE" "$PROMPT" "$prompt"
  exit 0
fi

if [[ "${BENCHMARK_SANDBOX:-0}" != 1 ]]; then
  echo "SETUP_FAIL=SANDBOX_REQUIRED" >&2
  exit 90
fi
case "$CASE" in
  trainer_checkpoint_vs_recovery_bundle_v1)
    exec bash "$(dirname "${BASH_SOURCE[0]}")/cases/trainer_checkpoint_vs_recovery_bundle_v1.sh"
    ;;
  feature_snapshot_vs_index_pack_v1)
    exec bash "$(dirname "${BASH_SOURCE[0]}")/cases/feature_snapshot_vs_index_pack_v1.sh"
    ;;
  *) echo "unknown CASE=$CASE" >&2; exit 2 ;;
esac

# Keep the static evaluator's actionability gate check visible at the packaged
# entrypoint; the selected case performs these checks immediately before its
# harness, against the trusted real holder PID.
# ACTIONABILITY_OK=1, SETUP_FAIL=INCUMBENT_NOT_ACTIONABLE, kill -0
