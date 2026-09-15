#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
case "$pid" in *[!0-9]*|'') exit 1 ;; esac
kill -0 "$pid" 2>/dev/null
[ "$(stat -c %U "/proc/$pid")" = "$AGENT_USER" ]
model-cachectl verify-manifest --cache "$CACHE_ROOT" --manifest "$A_MANIFEST" --lease "$A_LEASE" >/dev/null
python3 - "$A_PORT" "$A_LEASE" <<'PY'
import json, sys, urllib.request
port, lease = sys.argv[1:]
with urllib.request.urlopen(f"http://127.0.0.1:{port}/embed?text=warm-probe", timeout=1) as response:
    embed = json.load(response)
with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=1) as response:
    health = json.load(response)
if not health.get("warm_ready") or health.get("lease") != lease or int(embed.get("warm_hits", 0)) < 1:
    raise SystemExit(1)
if int(health.get("open_shards", 0)) != 2:
    raise SystemExit(1)
print(json.dumps({
    "pid": health["pid"], "revision": health["revision"], "lease": health["lease"],
    "warm_hits": health["warm_hits"], "warm_ready": health["warm_ready"],
    "open_shards": health["open_shards"],
}, sort_keys=True))
PY
printf 'A_HEALTHY=1 pid=%s lease=%s\n' "$pid" "$A_LEASE"
