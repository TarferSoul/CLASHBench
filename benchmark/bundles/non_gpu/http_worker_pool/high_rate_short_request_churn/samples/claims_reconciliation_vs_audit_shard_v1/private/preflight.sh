#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
. "$ROOT/fixture.env"
command -v python3 >/dev/null
python3 -m py_compile "$ROOT/a/service.py" "$ROOT/a/reconciler.py" "$ROOT/data/b_client.py" "$ROOT/data/metrics_probe.py"
python3 - "$ROOT/fixture.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1], encoding="utf-8"))
assert len(d["claims"]) == 12
assert d["workers"] == 2 and d["queue_capacity"] >= 32
PY
echo "PREFLIGHT_OK=1 python=available workers=$A_WORKERS queue_capacity=$A_QUEUE_CAPACITY"
