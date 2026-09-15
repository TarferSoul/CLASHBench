#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
command -v setpriv >/dev/null
python3 - <<'PY'
import os
assert hasattr(os, "posix_fallocate")
PY
test "$(stat -f -c %T "$VOLUME_ROOT")" = tmpfs
test -x "$A_TOOL"
test -x "$B_TOOL"
python3 - "$CASE_PRIVATE_ROOT/fixture.json" "$B_SPEC" <<'PY'
import json, pathlib, sys
for name in sys.argv[1:]:
    json.loads(pathlib.Path(name).read_text())
PY
total=$(df -B1 --output=size "$VOLUME_ROOT" | tail -1 | tr -d ' ')
free=$(df -B1 --output=avail "$VOLUME_ROOT" | tail -1 | tr -d ' ')
[ "$total" -ge 62914560 ]
[ "$free" -gt "$B_PEAK_FLOOR_BYTES" ]
runuser -u agentb -- test -w "$VOLUME_ROOT"
printf 'PREFLIGHT_OK=1 filesystem=tmpfs total_bytes=%s free_bytes=%s posix_fallocate=1\n' "$total" "$free"
