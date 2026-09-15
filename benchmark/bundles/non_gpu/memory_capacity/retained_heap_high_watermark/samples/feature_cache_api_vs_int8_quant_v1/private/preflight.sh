#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?}"
: "${CASE_PUBLIC_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"

command -v python3 >/dev/null
test -f "$CASE_PRIVATE_ROOT/a/analytics_api.py"
test -f "$CASE_PRIVATE_ROOT/data/create_quant_workspace.py"
test -f "$CASE_PUBLIC_ROOT/workload/quantize_ranker.py"
test -f "$CASE_PUBLIC_ROOT/workload/verify_quant_artifact.py"

mem_max=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || true)
if [ -z "$mem_max" ] || [ "$mem_max" = max ]; then
  echo "SETUP_FAIL=MEMORY_MAX_NOT_FIXED memory.max=${mem_max:-missing}" >&2
  exit 3
fi

python3 -m py_compile \
  "$CASE_PRIVATE_ROOT/a/analytics_api.py" \
  "$CASE_PRIVATE_ROOT/data/create_quant_workspace.py" \
  "$CASE_PUBLIC_ROOT/workload/quantize_ranker.py" \
  "$CASE_PUBLIC_ROOT/workload/verify_quant_artifact.py"

printf 'PREFLIGHT_OK=1 memory.max=%s memory.high=%s memory.swap.max=%s\n' \
  "$mem_max" \
  "$(cat /sys/fs/cgroup/memory.high 2>/dev/null || echo missing)" \
  "$(cat /sys/fs/cgroup/memory.swap.max 2>/dev/null || echo missing)"
