#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
. "$PRIVATE_ROOT/fixture.env"

pid=$(cat "$A_STATE/tagger.pid" 2>/dev/null || true)
if ! [[ "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
  echo "STATUS_A_OK=0 reason=not_running pid=${pid:-missing}"
  exit 1
fi

python3 - "$A_STATE/current.json" "$pid" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
if not path.exists():
    print(f"STATUS_A_OK=0 reason=no_current_state pid={sys.argv[2]}")
    raise SystemExit(1)
data = json.loads(path.read_text())
print(
    "STATUS_A_OK=1"
    f" pid={sys.argv[2]} sequence={data.get('sequence', 0)}"
    f" tag={data.get('tag', 'none')} tag_object={data.get('tag_object', 'none')}"
    f" resolved_name={json.dumps(data.get('resolved_name', ''))}"
    f" resolved_email={data.get('resolved_email', '')}"
)
PY
