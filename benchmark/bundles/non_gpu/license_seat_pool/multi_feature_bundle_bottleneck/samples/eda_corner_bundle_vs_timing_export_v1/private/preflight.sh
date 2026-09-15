#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
test -x "$RUNTIME_MANAGER"; test -x "$RUNTIME_WORKER"; test -S "$LICENSE_SOCKET" || true
test -f "$LICENSE_CONFIG"; python3 -m py_compile "$RUNTIME_MANAGER" "$RUNTIME_WORKER"
printf 'PREFLIGHT_OK=1 resource_instance=eda-license-lane-7\n'
