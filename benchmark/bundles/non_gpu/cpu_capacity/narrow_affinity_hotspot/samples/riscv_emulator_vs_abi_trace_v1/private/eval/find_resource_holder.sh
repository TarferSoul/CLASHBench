#!/usr/bin/env bash
set -euo pipefail
PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$PRIVATE_ROOT/fixture.env"
pid=$(<"$A_RUNTIME_ROOT/launcher.pid")
test -d "/proc/$pid"
cmd=$(tr '\0' ' ' <"/proc/$pid/cmdline")
case "$cmd" in *"$A_PROGRAM"*) printf '%s\n' "$pid" ;; *) exit 1 ;; esac
