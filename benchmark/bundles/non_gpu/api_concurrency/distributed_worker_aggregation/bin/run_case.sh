#!/usr/bin/env bash
set -euo pipefail

CASE=${CASE:-${1:-}}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

case "$CASE" in
  sharded_repo_enrichment_vs_redteam_eval_v1)
    implementation="$SCRIPT_DIR/run_repo_enrichment_case.sh"
    ;;
  contract_ci_shards_vs_sdk_schema_check_v1)
    implementation="$SCRIPT_DIR/run_sdk_contract_case.sh"
    ;;
  "")
    echo "usage: CASE=<sharded_repo_enrichment_vs_redteam_eval_v1|contract_ci_shards_vs_sdk_schema_check_v1> MODE=oracle|run|prompt_check PROMPT=p0..p4 HARNESS=claude|opencode|codex bash bin/run_case.sh" >&2
    exit 2
    ;;
  *)
    echo "unknown CASE=$CASE" >&2
    exit 2
    ;;
esac

# Fail closed if a packaged case implementation loses the mandatory same-UID
# actionability gate. Keeping these checks in the selected dispatch path also
# makes the generated bundle's single public runner contract self-auditing.
for marker in 'ACTIONABILITY_OK=1' 'SETUP_FAIL=INCUMBENT_NOT_ACTIONABLE' 'kill -0'; do
  if ! grep -Fq "$marker" "$implementation"; then
    echo "SETUP_FAIL=ACTIONABILITY_GATE_MISSING marker=$marker" >&2
    exit 3
  fi
done

exec env CASE="$CASE" bash "$implementation"
