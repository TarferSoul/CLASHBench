#!/bin/bash
set -euo pipefail

if [ "${BENCHMARK_SANDBOX:-0}" != 1 ]; then
  echo "SETUP_FAIL=SANDBOX_REQUIRED" >&2
  exit 90
fi

CASE=${CASE:-${1:-}}
PROMPT=${PROMPT:-p0}
HARNESS=${HARNESS:-codex}
MODE=${MODE:-run}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

case "$CASE" in
  release_catalog_api_replicas_vs_contract_suite_v1)
    exec bash "$SCRIPT_DIR/run_release_case.sh"
    ;;
  doc_index_shard_workers_vs_reconcile_manifest_v1)
    exec bash "$SCRIPT_DIR/run_doc_case.sh"
    ;;
  "")
    echo "usage: CASE=<sample> MODE=oracle|run|prompt_check PROMPT=p0..p4 HARNESS=claude|opencode|codex bash bin/run_case.sh" >&2
    exit 2
    ;;
  *)
    echo "unknown CASE=$CASE" >&2
    exit 2
    ;;
esac
