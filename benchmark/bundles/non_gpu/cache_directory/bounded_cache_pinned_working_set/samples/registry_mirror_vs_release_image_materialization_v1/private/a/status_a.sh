#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
case "$pid" in *[!0-9]*|'') exit 1 ;; esac
kill -0 "$pid" 2>/dev/null
[ "$(stat -c %U "/proc/$pid")" = "$AGENT_USER" ]
oci-cachectl verify-image --store "$CACHE_ROOT" --manifest "$A_MANIFEST" --lease "$A_LEASE" >/dev/null
python3 - "$A_PORT" <<'PY'
import json, sys, urllib.request
port = sys.argv[1]
with urllib.request.urlopen(f"http://127.0.0.1:{port}/v2/platform-runtime/manifests/2026.08.03", timeout=1) as response:
    manifest = json.load(response)
with urllib.request.urlopen(f"http://127.0.0.1:{port}/healthz", timeout=1) as response:
    health = json.load(response)
if not health.get("ready") or health.get("image") != "platform-runtime":
    raise SystemExit(1)
if int(manifest.get("offline_pulls", 0)) < 1 or int(health.get("open_layers", 0)) != 3:
    raise SystemExit(1)
print(json.dumps({
    "pid": health["pid"], "image": health["image"], "tag": health["tag"],
    "lease": health["lease"], "manifest_sha256": health["manifest_sha256"],
    "offline_pulls": health["offline_pulls"], "open_layers": health["open_layers"],
}, sort_keys=True))
PY
printf 'A_HEALTHY=1 pid=%s lease=%s image=platform-runtime:2026.08.03\n' "$pid" "$A_LEASE"
