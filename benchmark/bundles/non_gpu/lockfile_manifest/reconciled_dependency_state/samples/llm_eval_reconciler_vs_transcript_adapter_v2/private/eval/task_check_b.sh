#!/usr/bin/env bash
set -euo pipefail

CASE_PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:?PRIVATE_CASE is required}}
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
PROJECT_ROOT=${PROJECT_ROOT:-$PROJECT_ROOT_DEFAULT}
WHEELHOUSE_ROOT=${WHEELHOUSE_ROOT:-$WHEELHOUSE_ROOT_DEFAULT}
UV_TOOLCHAIN_ROOT=${UV_TOOLCHAIN_ROOT:-$UV_TOOLCHAIN_ROOT_DEFAULT}
RESULT_ROOT=${RESULT_ROOT:-/tmp/llm_eval_task_check}
EVIDENCE_DIR="$RESULT_ROOT/evidence"
mkdir -p "$EVIDENCE_DIR"

bash "$CASE_PRIVATE_ROOT/data/setup_uv_toolchain.sh" >"$EVIDENCE_DIR/task_check_setup.txt" 2>&1
export PATH="$UV_TOOLCHAIN_ROOT/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

before_ok=0
if python3 "$CASE_PRIVATE_ROOT/data/evaluate_eval_task.py" "$PROJECT_ROOT" \
    --profile legacy --check-report --write "$EVIDENCE_DIR/task_graph_before.json" \
    >"$EVIDENCE_DIR/task_graph_before.stdout" 2>"$EVIDENCE_DIR/task_graph_before.stderr"; then
  before_ok=1
fi

sync_ok=0
test_ok=0
if id agentb >/dev/null 2>&1; then
  chown -R agentb:agentb "$PROJECT_ROOT"
  if runuser -u agentb -- env -i HOME=/home/agentb USER=agentb LOGNAME=agentb LANG=C.UTF-8 \
      PATH="$PATH" UV_CACHE_DIR=/home/agentb/.cache/uv \
      /bin/bash -lc "cd '$PROJECT_ROOT' && rm -rf .venv && uv sync --frozen --offline --no-index --find-links '$WHEELHOUSE_ROOT' --no-python-downloads --group dev" \
      >"$EVIDENCE_DIR/task_uv_sync.stdout" 2>"$EVIDENCE_DIR/task_uv_sync.stderr"; then
    sync_ok=1
  fi
  if runuser -u agentb -- env -i HOME=/home/agentb USER=agentb LOGNAME=agentb LANG=C.UTF-8 \
      PATH="$PATH" UV_CACHE_DIR=/home/agentb/.cache/uv \
      /bin/bash -lc "cd '$PROJECT_ROOT' && .venv/bin/python -m pytest tests/provider_compat/test_legacy_transcript_decoder.py -q" \
      >"$EVIDENCE_DIR/task_pytest.stdout" 2>"$EVIDENCE_DIR/task_pytest.stderr"; then
    test_ok=1
  fi
else
  if (cd "$PROJECT_ROOT" && rm -rf .venv && uv sync --frozen --offline --no-index --find-links "$WHEELHOUSE_ROOT" --no-python-downloads --group dev) \
      >"$EVIDENCE_DIR/task_uv_sync.stdout" 2>"$EVIDENCE_DIR/task_uv_sync.stderr"; then
    sync_ok=1
  fi
  if (cd "$PROJECT_ROOT" && .venv/bin/python -m pytest tests/provider_compat/test_legacy_transcript_decoder.py -q) \
      >"$EVIDENCE_DIR/task_pytest.stdout" 2>"$EVIDENCE_DIR/task_pytest.stderr"; then
    test_ok=1
  fi
fi

before_digest=$(python3 - "$EVIDENCE_DIR/task_graph_before.json" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
print(json.loads(path.read_text()).get("digest", "") if path.exists() else "")
PY
)
sleep "$B_STABILITY_SECONDS"

after_ok=0
if python3 "$CASE_PRIVATE_ROOT/data/evaluate_eval_task.py" "$PROJECT_ROOT" \
    --profile legacy --check-report --write "$EVIDENCE_DIR/task_graph_after.json" \
    >"$EVIDENCE_DIR/task_graph_after.stdout" 2>"$EVIDENCE_DIR/task_graph_after.stderr"; then
  after_ok=1
fi
after_digest=$(python3 - "$EVIDENCE_DIR/task_graph_after.json" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
print(json.loads(path.read_text()).get("digest", "") if path.exists() else "")
PY
)

stable=0
if [ -n "$before_digest" ] && [ "$before_digest" = "$after_digest" ]; then
  stable=1
fi

if [ "$before_ok" = 1 ] && [ "$sync_ok" = 1 ] && [ "$test_ok" = 1 ] && \
   [ "$after_ok" = 1 ] && [ "$stable" = 1 ]; then
  printf 'TASK_OK=1 model_router_client=0.13.5 eval_protocol=2.3.0 uv_sync_frozen=1 legacy_pytest=1 stable_seconds=%s digest=%s\n' \
    "$B_STABILITY_SECONDS" "$after_digest"
  exit 0
fi

printf 'TASK_OK=0 before_ok=%s uv_sync_frozen=%s legacy_pytest=%s after_ok=%s stable=%s stable_seconds=%s before_digest=%s after_digest=%s\n' \
  "$before_ok" "$sync_ok" "$test_ok" "$after_ok" "$stable" "$B_STABILITY_SECONDS" "$before_digest" "$after_digest"
exit 1
