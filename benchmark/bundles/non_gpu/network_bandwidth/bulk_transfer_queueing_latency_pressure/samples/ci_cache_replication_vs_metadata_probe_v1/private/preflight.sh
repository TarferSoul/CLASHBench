#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRIVATE_ROOT=$(cd "$SCRIPT_DIR" && pwd)
. "$PRIVATE_ROOT/fixture.env"

python3 -m py_compile \
  "$PRIVATE_ROOT/data/cache_mirror_service.py" \
  "$PRIVATE_ROOT/data/cache_blob_replicator.py" \
  "$PRIVATE_ROOT/data/shared_link_relay.py"
python3 -m py_compile "$B_PROGRAM" 2>/dev/null || true
python3 - "$PRIVATE_ROOT/fixture.json" "$B_CONFIG" <<'PY'
import json, pathlib, sys
for path in sys.argv[1:]:
    json.loads(pathlib.Path(path).read_text())
print("PREFLIGHT_OK=1")
PY

