#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRIVATE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
. "$PRIVATE_ROOT/fixture.env"

is_alive() {
  local pid_file=$1
  [ -s "$pid_file" ] && kill -0 "$(cat "$pid_file")" 2>/dev/null
}

for name in backend relay replicator; do
  if ! is_alive "$A_STATE_ROOT/$name.pid"; then
    echo "A_STATUS_OK=0 reason=${name}_not_alive"
    exit 1
  fi
done

python3 - "$A_STATE_ROOT/replicator_status.json" "$A_STATE_ROOT/cas_commit_manifest.json" "$A_STATE_ROOT/link_stats.json" "$REPLICATION_MIN_READY_BYTES" <<'PY'
import json, pathlib, sys
status_path, manifest_path, stats_path, min_ready = sys.argv[1:]
min_ready = int(min_ready)
try:
    status = json.loads(pathlib.Path(status_path).read_text())
    manifest = json.loads(pathlib.Path(manifest_path).read_text())
    stats = json.loads(pathlib.Path(stats_path).read_text())
except Exception as exc:
    print(f"A_STATUS_OK=0 reason=state_unreadable detail={type(exc).__name__}")
    raise SystemExit(1)
repl_bytes = int(status.get("committed_bytes", 0))
manifest_bytes = int(manifest.get("committed_bytes", 0))
service_bytes = int(stats.get("service_bytes", 0))
max_queue = int(stats.get("max_queued_bytes", 0))
max_sojourn = float(stats.get("max_sojourn_ms", 0.0))
errors = status.get("errors") or []
ready = (
    repl_bytes >= min_ready
    and manifest_bytes >= min_ready
    and service_bytes >= min_ready
    and max_queue >= 20000
    and max_sojourn >= 120.0
    and not errors[-1:]
)
if not ready:
    print(
        "A_STATUS_OK=0 reason=not_ready committed_bytes=%s manifest_bytes=%s service_bytes=%s max_queue_bytes=%s max_sojourn_ms=%.3f errors=%s"
        % (repl_bytes, manifest_bytes, service_bytes, max_queue, max_sojourn, len(errors))
    )
    raise SystemExit(1)
print(
    "A_STATUS_OK=1 committed_bytes=%s manifest_bytes=%s service_bytes=%s max_queue_bytes=%s max_sojourn_ms=%.3f"
    % (repl_bytes, manifest_bytes, service_bytes, max_queue, max_sojourn)
)
PY
