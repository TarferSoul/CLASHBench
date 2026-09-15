#!/usr/bin/env bash
set -euo pipefail

CASE_PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:?PRIVATE_CASE is required}}
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
PROJECT_ROOT=${PROJECT_ROOT:-$PROJECT_ROOT_DEFAULT}
WHEELHOUSE_ROOT=${WHEELHOUSE_ROOT:-$WHEELHOUSE_ROOT_DEFAULT}
UV_TOOLCHAIN_ROOT=${UV_TOOLCHAIN_ROOT:-$UV_TOOLCHAIN_ROOT_DEFAULT}
export CASE_PRIVATE_ROOT PROJECT_ROOT WHEELHOUSE_ROOT UV_TOOLCHAIN_ROOT

bash "$CASE_PRIVATE_ROOT/data/setup_uv_toolchain.sh" >/tmp/llm_eval_apply_setup.log 2>&1
export PATH="$UV_TOOLCHAIN_ROOT/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

run_as_agent() {
  if id agentb >/dev/null 2>&1; then
    chown -R agentb:agentb "$PROJECT_ROOT"
    runuser -u agentb -- env -i \
      HOME=/home/agentb USER=agentb LOGNAME=agentb LANG=C.UTF-8 \
      PATH="$PATH" UV_CACHE_DIR=/home/agentb/.cache/uv \
      WHEELHOUSE_ROOT="$WHEELHOUSE_ROOT" \
      /bin/bash -lc "$1"
  else
    /bin/bash -lc "$1"
  fi
}

run_as_agent "
  set -euo pipefail
  cd '$PROJECT_ROOT'
  python3 tools/pin_legacy_eval_graph.py
  uv lock --offline --no-index --find-links '$WHEELHOUSE_ROOT' --no-python-downloads
  rm -rf .venv
  uv sync --frozen --offline --no-index --find-links '$WHEELHOUSE_ROOT' --no-python-downloads --group dev
  .venv/bin/python -m pytest tests/provider_compat/test_legacy_transcript_decoder.py -q
  .venv/bin/python tools/write_legacy_transcript_report.py
"
