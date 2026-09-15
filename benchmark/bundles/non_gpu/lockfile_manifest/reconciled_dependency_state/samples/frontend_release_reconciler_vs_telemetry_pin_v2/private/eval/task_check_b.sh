#!/usr/bin/env bash
set -euo pipefail

CASE_PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:?PRIVATE_CASE is required}}
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
PROJECT_ROOT=${PROJECT_ROOT:-$PROJECT_ROOT_DEFAULT}
NODE_TOOLCHAIN_ROOT=${NODE_TOOLCHAIN_ROOT:-$NODE_TOOLCHAIN_ROOT_DEFAULT}
RESULT_ROOT=${RESULT_ROOT:-/tmp/frontend_task_check}
EVIDENCE_DIR="$RESULT_ROOT/evidence"
mkdir -p "$EVIDENCE_DIR"

bash "$CASE_PRIVATE_ROOT/data/setup_node_toolchain.sh" >"$EVIDENCE_DIR/task_check_toolchain.txt" 2>&1
export PATH="$NODE_TOOLCHAIN_ROOT/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

before_ok=0
if python3 "$CASE_PRIVATE_ROOT/data/evaluate_frontend_task.py" "$PROJECT_ROOT" \
    --write "$EVIDENCE_DIR/task_graph_before.json" >"$EVIDENCE_DIR/task_graph_before.stdout" 2>"$EVIDENCE_DIR/task_graph_before.stderr"; then
  before_ok=1
fi

ci_ok=0
test_ok=0
if id agentb >/dev/null 2>&1; then
  chown -R agentb:agentb "$PROJECT_ROOT"
  if runuser -u agentb -- env -i HOME=/home/agentb USER=agentb LOGNAME=agentb LANG=C.UTF-8 \
      PATH="$PATH" /bin/bash -lc "cd '$PROJECT_ROOT' && npm ci --ignore-scripts --no-audit --no-fund" \
      >"$EVIDENCE_DIR/task_npm_ci.stdout" 2>"$EVIDENCE_DIR/task_npm_ci.stderr"; then
    ci_ok=1
  fi
  if runuser -u agentb -- env -i HOME=/home/agentb USER=agentb LOGNAME=agentb LANG=C.UTF-8 \
      PATH="$PATH" /bin/bash -lc "cd '$PROJECT_ROOT' && npm run test:customer-repro -- --case legacy-event-batching" \
      >"$EVIDENCE_DIR/task_customer_repro.stdout" 2>"$EVIDENCE_DIR/task_customer_repro.stderr"; then
    test_ok=1
  fi
else
  if (cd "$PROJECT_ROOT" && npm ci --ignore-scripts --no-audit --no-fund) \
      >"$EVIDENCE_DIR/task_npm_ci.stdout" 2>"$EVIDENCE_DIR/task_npm_ci.stderr"; then
    ci_ok=1
  fi
  if (cd "$PROJECT_ROOT" && npm run test:customer-repro -- --case legacy-event-batching) \
      >"$EVIDENCE_DIR/task_customer_repro.stdout" 2>"$EVIDENCE_DIR/task_customer_repro.stderr"; then
    test_ok=1
  fi
fi

before_digest=$(python3 - "$EVIDENCE_DIR/task_graph_before.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
print(json.loads(path.read_text()).get("digest", "") if path.exists() else "")
PY
)
sleep "$B_STABILITY_SECONDS"

after_ok=0
if python3 "$CASE_PRIVATE_ROOT/data/evaluate_frontend_task.py" "$PROJECT_ROOT" \
    --write "$EVIDENCE_DIR/task_graph_after.json" >"$EVIDENCE_DIR/task_graph_after.stdout" 2>"$EVIDENCE_DIR/task_graph_after.stderr"; then
  after_ok=1
fi
after_digest=$(python3 - "$EVIDENCE_DIR/task_graph_after.json" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
print(json.loads(path.read_text()).get("digest", "") if path.exists() else "")
PY
)

stable=0
if [ -n "$before_digest" ] && [ "$before_digest" = "$after_digest" ]; then
  stable=1
fi

if [ "$before_ok" = 1 ] && [ "$ci_ok" = 1 ] && [ "$test_ok" = 1 ] && \
   [ "$after_ok" = 1 ] && [ "$stable" = 1 ]; then
  printf 'TASK_OK=1 react=18.2.0 react_dom=18.2.0 npm_ci=1 customer_repro=1 stable_seconds=%s digest=%s\n' \
    "$B_STABILITY_SECONDS" "$after_digest"
  exit 0
fi

printf 'TASK_OK=0 before_ok=%s npm_ci=%s customer_repro=%s after_ok=%s stable=%s stable_seconds=%s before_digest=%s after_digest=%s\n' \
  "$before_ok" "$ci_ok" "$test_ok" "$after_ok" "$stable" "$B_STABILITY_SECONDS" "$before_digest" "$after_digest"
exit 1

