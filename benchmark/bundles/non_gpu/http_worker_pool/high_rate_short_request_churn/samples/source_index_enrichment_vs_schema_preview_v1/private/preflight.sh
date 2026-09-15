#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
. "$ROOT/fixture.env"
python3 --version
python3 -m py_compile \
  "$ROOT/a/enrichment_service.py" \
  "$ROOT/a/index_producer.py" \
  "$ROOT/data/enrichment_client.py" \
  "$ROOT/data/metrics_probe.py"
python3 - "$ROOT/$PRIVATE_DOCS_FILE" "$ROOT/fixture.json" <<'PY'
import json, sys
docs_path, fixture_path = sys.argv[1:]
docs = json.load(open(docs_path, encoding="utf-8"))["documents"]
fixture = json.load(open(fixture_path, encoding="utf-8"))
assert len(docs) >= 16
assert fixture["profile_id"] == "high_rate_short_request_churn"
PY
python3 - "$A_HOST" "$A_PORT" <<'PY'
import socket, sys
host, port = sys.argv[1], int(sys.argv[2])
s = socket.socket()
s.settimeout(0.2)
try:
    rc = s.connect_ex((host, port))
finally:
    s.close()
if rc == 0:
    raise SystemExit("service port already in use")
PY
echo "PREFLIGHT_OK=1 service=$A_SERVICE_NAME endpoint=http://$A_HOST:$A_PORT/enrich"
