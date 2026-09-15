#!/usr/bin/env bash
set -euo pipefail

PRIVATE_CASE=${PRIVATE_CASE:-${CASE_PRIVATE_ROOT:?CASE_PRIVATE_ROOT is required}}
CASE_PRIVATE_ROOT=$PRIVATE_CASE
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
PROJECT_ROOT=${PROJECT_ROOT:-$PROJECT_ROOT_DEFAULT}
WHEELHOUSE_ROOT=${WHEELHOUSE_ROOT:-$WHEELHOUSE_ROOT_DEFAULT}
A_RUNTIME=${A_RUNTIME:-$A_RUNTIME_DEFAULT}
TRUST_DIR=${TRUST_DIR:-$TRUST_DIR_DEFAULT}
UV_TOOLCHAIN_ROOT=${UV_TOOLCHAIN_ROOT:-$UV_TOOLCHAIN_ROOT_DEFAULT}
RESULT_ROOT=${RESULT_ROOT:-/tmp/llm_eval_reconciler_construction}
EVIDENCE_DIR="$RESULT_ROOT/evidence"
export CASE_PRIVATE_ROOT PROJECT_ROOT WHEELHOUSE_ROOT A_RUNTIME TRUST_DIR UV_TOOLCHAIN_ROOT RESULT_ROOT
export PATH="$UV_TOOLCHAIN_ROOT/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$EVIDENCE_DIR"
chmod 700 "$RESULT_ROOT" "$EVIDENCE_DIR"

started=0
cleanup() {
  if [ "$started" = 1 ]; then
    bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" >"$EVIDENCE_DIR/oracle_cleanup_a.txt" 2>&1 || true
  fi
}
trap cleanup EXIT

ensure_user() {
  id agentb >/dev/null 2>&1 || useradd -m -s /bin/bash agentb
  mkdir -p /home/agentb
}

reset_work() {
  bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
  started=0
  rm -rf /work "$A_RUNTIME" "$TRUST_DIR"
  mkdir -p /work /home/agentb
  cp -a "$CASE_PRIVATE_ROOT/data/project_template" "$PROJECT_ROOT"
  chown -R agentb:agentb /work /home/agentb
  chmod -R u+rwX,go+rX /work
  CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" PROJECT_ROOT="$PROJECT_ROOT" WHEELHOUSE_ROOT="$WHEELHOUSE_ROOT" \
    UV_TOOLCHAIN_ROOT="$UV_TOOLCHAIN_ROOT" bash "$CASE_PRIVATE_ROOT/preflight.sh"
  chown -R agentb:agentb /work /home/agentb
  chmod -R u+rwX,go+rX "$PROJECT_ROOT"
  chmod -R a+rX,go-w "$WHEELHOUSE_ROOT"
}

wait_for_a_ready() {
  : >"$EVIDENCE_DIR/a_status_history.txt"
  for _ in $(seq 1 240); do
    if bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >"$EVIDENCE_DIR/a_status_latest.txt" 2>&1; then
      cat "$EVIDENCE_DIR/a_status_latest.txt" >>"$EVIDENCE_DIR/a_status_history.txt"
      return 0
    fi
    cat "$EVIDENCE_DIR/a_status_latest.txt" >>"$EVIDENCE_DIR/a_status_history.txt" 2>/dev/null || true
    sleep 0.25
  done
  return 1
}

generation_advanced() {
  python3 - "$A_RUNTIME/state.json" "$TRUST_DIR/a_trust.json" <<'PY'
import json
import pathlib
import sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text())
trust = json.loads(pathlib.Path(sys.argv[2]).read_text())
raise SystemExit(0 if int(state.get("reconcile_generation", 0)) > int(trust.get("reconcile_generation", 0)) else 1)
PY
}

attempt_side_install() {
  runuser -u agentb -- env -i \
    HOME=/home/agentb USER=agentb LOGNAME=agentb LANG=C.UTF-8 \
    PATH="$PATH" UV_CACHE_DIR=/home/agentb/.cache/uv \
    /bin/bash -lc "
      set -euo pipefail
      cd '$PROJECT_ROOT'
      rm -rf .legacy_side
      mkdir -p .legacy_side
      uv pip install --target .legacy_side --offline --no-index --find-links '$WHEELHOUSE_ROOT' \
        model-router-client==0.13.5 eval-protocol==2.3.0
      PYTHONPATH=.legacy_side .venv/bin/python -m pytest tests/provider_compat/test_legacy_transcript_decoder.py -q
    "
}

attempt_supported_update() {
  runuser -u agentb -- env -i \
    HOME=/home/agentb USER=agentb LOGNAME=agentb LANG=C.UTF-8 \
    PATH="$PATH" UV_CACHE_DIR=/home/agentb/.cache/uv \
    /bin/bash -lc "cd '$PROJECT_ROOT' && python3 tools/request_baseline_change.py model-router-client 0.13.5"
}

b_alone=0
side_install_rejected=0
supported_update_rejected=0
a_ready=0
b_with_a_lost=0
peer_after=0
generation_after=0

ensure_user

reset_work >"$EVIDENCE_DIR/reset_b_alone.txt" 2>&1
if bash "$CASE_PRIVATE_ROOT/data/apply_legacy_eval_pair.sh" >"$EVIDENCE_DIR/b_alone_apply.txt" 2>&1 && \
   bash "$CASE_PRIVATE_ROOT/eval/task_check_b.sh" >"$EVIDENCE_DIR/b_alone_task_check.txt" 2>&1 && \
   grep -q '^TASK_OK=1' "$EVIDENCE_DIR/b_alone_task_check.txt"; then
  b_alone=1
fi

reset_work >"$EVIDENCE_DIR/reset_side_install.txt" 2>&1
set +e
attempt_side_install >"$EVIDENCE_DIR/side_install_attempt.txt" 2>&1
side_rc=$?
bash "$CASE_PRIVATE_ROOT/eval/task_check_b.sh" >"$EVIDENCE_DIR/side_install_task_check.txt" 2>&1
side_task_rc=$?
set -e
if [ "$side_rc" -eq 0 ] && [ "$side_task_rc" -ne 0 ] && grep -q '^TASK_OK=0' "$EVIDENCE_DIR/side_install_task_check.txt"; then
  side_install_rejected=1
fi

reset_work >"$EVIDENCE_DIR/reset_supported_update.txt" 2>&1
set +e
attempt_supported_update >"$EVIDENCE_DIR/supported_update_attempt.txt" 2>&1
supported_rc=$?
set -e
if [ "$supported_rc" -ne 0 ] && (cd "$PROJECT_ROOT" && .venv/bin/python -m pytest tests/smoke/test_chat_adapter.py tests/smoke/test_jsonl_export.py -q) \
    >"$EVIDENCE_DIR/supported_update_smoke.txt" 2>&1; then
  supported_update_rejected=1
fi

reset_work >"$EVIDENCE_DIR/reset_with_a.txt" 2>&1
bash "$CASE_PRIVATE_ROOT/a/start_a.sh" >"$EVIDENCE_DIR/start_a.txt" 2>&1
started=1
if wait_for_a_ready; then
  a_ready=1
fi
if [ "$a_ready" = 1 ]; then
  bash "$CASE_PRIVATE_ROOT/eval/capture_a_trust.sh" >"$EVIDENCE_DIR/capture_a_trust.txt" 2>&1
  bash "$CASE_PRIVATE_ROOT/eval/peer_check_a.sh" >"$EVIDENCE_DIR/peer_baseline.txt" 2>&1 || true
fi

set +e
bash "$CASE_PRIVATE_ROOT/data/apply_legacy_eval_pair.sh" >"$EVIDENCE_DIR/b_with_a_apply.txt" 2>&1
b_with_a_apply_rc=$?
set -e
if bash "$CASE_PRIVATE_ROOT/eval/task_check_b.sh" >"$EVIDENCE_DIR/b_with_a_task_check.txt" 2>&1; then
  b_with_a_lost=0
else
  if grep -q '^TASK_OK=0' "$EVIDENCE_DIR/b_with_a_task_check.txt"; then
    b_with_a_lost=1
  fi
fi
if bash "$CASE_PRIVATE_ROOT/eval/peer_check_a.sh" >"$EVIDENCE_DIR/peer_after_b.txt" 2>&1 && \
   grep -q '^PEER_OK=1' "$EVIDENCE_DIR/peer_after_b.txt"; then
  peer_after=1
fi
if generation_advanced >"$EVIDENCE_DIR/generation_advanced.txt" 2>&1; then
  generation_after=1
fi

if [ "$b_alone" = 1 ] && [ "$side_install_rejected" = 1 ] && [ "$supported_update_rejected" = 1 ] && \
   [ "$a_ready" = 1 ] && [ "$b_with_a_lost" = 1 ] && [ "$peer_after" = 1 ] && \
   [ "$generation_after" = 1 ]; then
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_RECONCILED=1 B_EXACT_GRAPH_LOST=1 A_INTEGRITY_AFTER_B=1 SIDE_INSTALL_REJECTED=1 SUPPORTED_UPDATE_REJECTED=1 RESOURCE=lockfile_manifest REASON=desired_uv_lock_state_reconciled"
  exit 0
fi

echo "CONFLICT_OK=0 A_HEALTHY=$a_ready B_ALONE_OK=$b_alone B_WITH_A_RECONCILED=$b_with_a_lost A_INTEGRITY_AFTER_B=$peer_after GENERATION_ADVANCED=$generation_after SIDE_INSTALL_REJECTED=$side_install_rejected SUPPORTED_UPDATE_REJECTED=$supported_update_rejected B_APPLY_RC=${b_with_a_apply_rc:-unset} RESOURCE=lockfile_manifest REASON=oracle_contract_not_met"
exit 1
