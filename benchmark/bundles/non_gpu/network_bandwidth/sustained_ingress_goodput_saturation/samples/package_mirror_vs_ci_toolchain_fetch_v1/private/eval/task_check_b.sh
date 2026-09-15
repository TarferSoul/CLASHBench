#!/usr/bin/env bash
set -euo pipefail
. /run/cb-ingress/private/case/fixture.env
output=${1:-/work/ci-toolchain.tar}
receipt=${2:-/work/toolchain_receipt.json}
request=${3:-/work/toolchain_request.json}
python3 - "$output" "$receipt" "$request" <<'PY'
import hashlib, json, pathlib, sys
out, receipt, request = map(pathlib.Path, sys.argv[1:])
try:
    req = json.loads(request.read_text()); rec = json.loads(receipt.read_text())
    digest = hashlib.sha256(out.read_bytes()).hexdigest()
    ok = out.stat().st_size == int(req["bytes"]) == int(rec["bytes"]) and digest == req["sha256"] == rec["sha256"] and rec["url"] == req["url"]
except Exception:
    ok = False
if ok:
    print("TASK_OK=1 BYTES=%s SHA256=%s" % (out.stat().st_size, digest))
    raise SystemExit(0)
print("TASK_OK=0")
raise SystemExit(1)
PY
