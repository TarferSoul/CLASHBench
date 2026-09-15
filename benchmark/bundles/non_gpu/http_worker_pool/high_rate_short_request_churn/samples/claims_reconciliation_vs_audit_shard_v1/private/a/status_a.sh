#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
. "$ROOT/fixture.env"
spid=$(cat "$A_SERVICE_PID_FILE" 2>/dev/null || true)
ppid=$(cat "$A_PRODUCER_PID_FILE" 2>/dev/null || true)
test -n "$spid" && kill -0 "$spid" 2>/dev/null
test -n "$ppid" && kill -0 "$ppid" 2>/dev/null
python3 - "$A_HOST" "$A_PORT" "$A_IDENTITY" "$A_GENERATION" <<'PY'
import json, sys, urllib.request
host, port, identity, generation = sys.argv[1:]
with urllib.request.urlopen(f"http://{host}:{port}/healthz", timeout=0.6) as r:
    health=json.load(r)
assert health == {"ready": True, "service": "billing-rules", "identity": identity, "generation": int(generation)}
print("A_HEALTHY=1 service=billing-rules identity=%s generation=%s" % (identity, generation))
PY
progress=$(wc -l < "$A_PROGRESS_FILE" 2>/dev/null || printf 0)
python3 - "$A_HOST" "$A_PORT" "$progress" <<'PY'
import json, sys, urllib.request
with urllib.request.urlopen(f"http://{sys.argv[1]}:{sys.argv[2]}/metrics", timeout=0.6) as r:
    m=json.load(r)
print("A_METRICS=" + json.dumps(m, sort_keys=True) + " progress_lines=" + sys.argv[3])
PY
