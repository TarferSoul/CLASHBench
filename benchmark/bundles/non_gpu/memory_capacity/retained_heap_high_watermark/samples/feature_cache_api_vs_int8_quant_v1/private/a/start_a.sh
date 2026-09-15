#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"

install -d -o agentb -g agentb -m 700 "$A_RUN_DIR"
install -d -o root -g root -m 700 "$TRUST_ROOT"
rm -f "$A_PID_FILE" "$A_RUN_DIR/service.log"

FEATURE_CACHE_PORT="$A_PORT" \
FEATURE_CACHE_TARGET_PCT="$A_CACHE_TARGET_PCT" \
FEATURE_CACHE_CHUNK_MIB="$A_CACHE_CHUNK_MIB" \
runuser -u agentb -- setsid bash -c 'exec -a feature-cache-api python3 "$0"' "$A_PROGRAM" \
  >"$A_RUN_DIR/service.log" 2>&1 &

python3 - "$A_PORT" "$A_WARM_TIMEOUT_SECONDS" "$A_PID_FILE" <<'PY'
import json
import sys
import time
import urllib.request

port = int(sys.argv[1])
deadline = time.monotonic() + float(sys.argv[2])

def get(path, timeout=1.0):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))

while time.monotonic() < deadline:
    try:
        get("/metrics", timeout=0.2)
        break
    except Exception:
        time.sleep(0.1)
else:
    raise SystemExit("service port did not become reachable")

remaining = max(5.0, deadline - time.monotonic())
payload = get("/warm_feature_cache", timeout=remaining)
if not payload.get("ok"):
    raise SystemExit("warm_feature_cache did not report ok")
Path = __import__("pathlib").Path
Path(sys.argv[3]).write_text(str(int(payload["pid"])) + "\n", encoding="utf-8")
print(json.dumps(payload, sort_keys=True))
PY

bash "$CASE_PRIVATE_ROOT/a/status_a.sh"
