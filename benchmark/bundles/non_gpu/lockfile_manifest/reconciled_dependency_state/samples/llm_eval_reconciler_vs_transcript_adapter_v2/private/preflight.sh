#!/usr/bin/env bash
set -euo pipefail

CASE_PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:?PRIVATE_CASE is required}}
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
PROJECT_ROOT=${PROJECT_ROOT:-$PROJECT_ROOT_DEFAULT}
WHEELHOUSE_ROOT=${WHEELHOUSE_ROOT:-$WHEELHOUSE_ROOT_DEFAULT}
UV_TOOLCHAIN_ROOT=${UV_TOOLCHAIN_ROOT:-$UV_TOOLCHAIN_ROOT_DEFAULT}
export CASE_PRIVATE_ROOT PROJECT_ROOT WHEELHOUSE_ROOT UV_TOOLCHAIN_ROOT

bash "$CASE_PRIVATE_ROOT/data/setup_uv_toolchain.sh"
export PATH="$UV_TOOLCHAIN_ROOT/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export UV_CACHE_DIR=/tmp/llm_eval_uv_cache

run_logged() {
  local label=$1
  local log=$2
  shift 2
  if ! "$@" >"$log" 2>&1; then
    printf 'PREFLIGHT_FAIL=%s log=%s\n' "$label" "$log" >&2
    sed -n '1,220p' "$log" >&2 || true
    exit 22
  fi
}

test -d "$PROJECT_ROOT"
cd "$PROJECT_ROOT"
run_logged uv_lock /tmp/llm_eval_preflight_lock.log \
  uv lock --offline --no-index --find-links "$WHEELHOUSE_ROOT" --no-python-downloads
run_logged uv_sync /tmp/llm_eval_preflight_sync.log \
  uv sync --frozen --offline --no-index --find-links "$WHEELHOUSE_ROOT" --no-python-downloads --group dev
run_logged smoke /tmp/llm_eval_preflight_smoke.log \
  .venv/bin/python -m pytest tests/smoke/test_chat_adapter.py tests/smoke/test_jsonl_export.py -q
printf 'PREFLIGHT_OK=1 project=%s wheelhouse=%s\n' "$PROJECT_ROOT" "$WHEELHOUSE_ROOT"
