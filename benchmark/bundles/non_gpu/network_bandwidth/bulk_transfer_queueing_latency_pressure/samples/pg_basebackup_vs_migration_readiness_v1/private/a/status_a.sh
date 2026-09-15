#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRIVATE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
. "$PRIVATE_ROOT/fixture.env"

for name in backend relay publisher; do
  pid_file="$A_STATE_ROOT/$name.pid"
  [ -s "$pid_file" ] || { echo "A_STATUS_FAIL missing_${name}_pid"; exit 1; }
  kill -0 "$(cat "$pid_file")" 2>/dev/null || { echo "A_STATUS_FAIL ${name}_not_alive"; exit 1; }
done

python3 - "$BACKEND_HOST" "$BACKEND_PORT" "$A_STATE_ROOT/backup_manifest.json" "$A_STATE_ROOT/link_stats.json" "$BACKUP_SEGMENT_BYTES" <<'PY'
import http.client, json, pathlib, sys
host, port, manifest_path, stats_path, segment_bytes = sys.argv[1], int(sys.argv[2]), pathlib.Path(sys.argv[3]), pathlib.Path(sys.argv[4]), int(sys.argv[5])
conn = http.client.HTTPConnection(host, port, timeout=2)
try:
    conn.request("GET", "/health")
    response = conn.getresponse()
    body = response.read()
    if response.status != 200 or json.loads(body.decode()).get("ok") is not True:
        raise SystemExit("backend_health_bad")
finally:
    conn.close()
manifest = json.loads(manifest_path.read_text())
stats = json.loads(stats_path.read_text())
committed = int(manifest.get("committed_bytes", 0))
service = int(stats.get("service_bytes", 0))
max_queue = int(stats.get("max_queued_bytes", 0))
if committed < segment_bytes:
    raise SystemExit(f"manifest_not_ready committed={committed}")
if service < segment_bytes:
    raise SystemExit(f"link_service_not_ready service={service}")
if max_queue < min(65536, int(stats.get("queue_limit_bytes", 0)) // 3):
    raise SystemExit(f"queue_not_observed max_queue={max_queue}")
print(
    "A_STATUS_OK=1 committed_bytes=%s segments=%s service_bytes=%s max_queue_bytes=%s max_sojourn_ms=%.3f"
    % (
        committed,
        len(manifest.get("segments", [])),
        service,
        max_queue,
        float(stats.get("max_sojourn_ms", 0.0)),
    )
)
PY
