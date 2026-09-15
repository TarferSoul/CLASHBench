#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - <<'PY'
import os
assert hasattr(os, "posix_fallocate")
PY
python3 - "$CASE_PRIVATE_ROOT/fixture.json" "$B_SPEC" <<'PY'
import json, sys
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as handle:
        json.load(handle)
PY
test -x "$B_TOOL"
test -x "$INCUMBENT_TOOL"
test "$(stat -Lc %u "$VOLUME_ROOT")" = "$(id -u agentb)"
total=$(python3 - "$VOLUME_ROOT" <<'PY'
import os, sys
s = os.statvfs(sys.argv[1])
print(s.f_blocks * s.f_frsize)
PY
)
free=$(python3 - "$VOLUME_ROOT" <<'PY'
import os, sys
s = os.statvfs(sys.argv[1])
print(s.f_bavail * s.f_frsize)
PY
)
[ "$total" -ge 62914560 ]
[ "$free" -gt "$B_BYTES" ]
printf 'PREFLIGHT_OK=1 filesystem=%s total_bytes=%s free_bytes=%s b_bytes=%s\n' \
  "$(stat -f -c %T "$VOLUME_ROOT")" "$total" "$free" "$B_BYTES"
