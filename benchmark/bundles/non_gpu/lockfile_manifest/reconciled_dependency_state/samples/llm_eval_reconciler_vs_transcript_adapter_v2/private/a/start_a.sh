#!/usr/bin/env bash
set -euo pipefail

CASE_PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-${PRIVATE_CASE:?PRIVATE_CASE is required}}
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
PROJECT_ROOT=${PROJECT_ROOT:-$PROJECT_ROOT_DEFAULT}
WHEELHOUSE_ROOT=${WHEELHOUSE_ROOT:-$WHEELHOUSE_ROOT_DEFAULT}
A_RUNTIME=${A_RUNTIME:-$A_RUNTIME_DEFAULT}
UV_TOOLCHAIN_ROOT=${UV_TOOLCHAIN_ROOT:-$UV_TOOLCHAIN_ROOT_DEFAULT}
DESIRED_SOURCE="$CASE_PRIVATE_ROOT/data/desired/$DESIRED_REVISION.json"
export CASE_PRIVATE_ROOT PROJECT_ROOT WHEELHOUSE_ROOT A_RUNTIME UV_TOOLCHAIN_ROOT

bash "$CASE_PRIVATE_ROOT/data/setup_uv_toolchain.sh" >/dev/null
export PATH="$UV_TOOLCHAIN_ROOT/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$A_RUNTIME"
chown -R agentb:agentb "$A_RUNTIME"
chmod 700 "$A_RUNTIME"
rm -f "$A_RUNTIME/handoff.done" "$A_RUNTIME/pid"
cp "$DESIRED_SOURCE" "$A_RUNTIME/desired.json"
install -m 755 "$CASE_PRIVATE_ROOT/data/eval_baseline_reconciler.py" "$A_RUNTIME/eval_baseline_reconciler.py"
chown agentb:agentb "$A_RUNTIME/desired.json" "$A_RUNTIME/eval_baseline_reconciler.py"
chmod 600 "$A_RUNTIME/desired.json"
: >"$A_RUNTIME/controller.log"
chown agentb:agentb "$A_RUNTIME/controller.log"

launcher=(env -i PATH="$PATH" LANG=C.UTF-8 PYTHONUNBUFFERED=1
  python3 "$A_RUNTIME/eval_baseline_reconciler.py"
    --project "$PROJECT_ROOT"
    --desired "$A_RUNTIME/desired.json"
    --runtime "$A_RUNTIME"
    --wheelhouse "$WHEELHOUSE_ROOT"
    --handoff-marker "$A_RUNTIME/handoff.done"
    --watch-interval "$A_WATCH_SECONDS"
    --audit-interval "$A_AUDIT_SECONDS")

if command -v setsid >/dev/null 2>&1; then
  runuser -u agentb -- setsid "${launcher[@]}" >"$A_RUNTIME/controller.log" 2>&1 &
else
  runuser -u agentb -- "${launcher[@]}" >"$A_RUNTIME/controller.log" 2>&1 &
fi
pid=$!
printf '%s\n' "$pid" >"$A_RUNTIME/pid"
chmod 600 "$A_RUNTIME/pid"

ready=0
for _ in $(seq 1 240); do
  if CASE_PRIVATE_ROOT="$CASE_PRIVATE_ROOT" PROJECT_ROOT="$PROJECT_ROOT" A_RUNTIME="$A_RUNTIME" \
      bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >/tmp/llm_eval_reconciler_status.txt 2>&1; then
    ready=1
    break
  fi
  sleep 0.25
done

if [ "$ready" != 1 ]; then
  cat /tmp/llm_eval_reconciler_status.txt >&2 2>/dev/null || true
  sed -n '1,160p' "$A_RUNTIME/controller.log" >&2 2>/dev/null || true
  exit 1
fi

cat /tmp/llm_eval_reconciler_status.txt
