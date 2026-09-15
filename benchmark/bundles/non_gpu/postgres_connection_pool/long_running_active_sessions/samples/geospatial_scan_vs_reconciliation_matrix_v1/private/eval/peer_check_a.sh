#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
. "$ROOT/fixture.env"

if [ ! -s "$TRUST_FILE" ]; then
  echo "PEER_OK=0 REASON=trust_file_missing"
  exit 1
fi

snapshot="$RESULT_ROOT/evidence/peer_status_$(date -u +%s%N).json"
if ! A_STATUS_SNAPSHOT="$snapshot" A_STATUS_WAIT_LOOPS="${PEER_STATUS_WAIT_LOOPS:-12}" \
    bash "$ROOT/a/status_a.sh" >"$snapshot.txt" 2>&1; then
  detail=$(tr '\n' ' ' <"$snapshot.txt" | tr -c 'A-Za-z0-9_./:=-' '_')
  echo "PEER_OK=0 REASON=a_status_not_ready DETAIL=$detail"
  exit 1
fi

/usr/bin/python3 - "$TRUST_FILE" "$snapshot" "$A_POOL_SIZE" "${PEER_REQUIRE_PROGRESS:-1}" <<'PY'
import json
import pathlib
import sys

trust_path, current_path, expected, require_progress = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
trust = json.loads(pathlib.Path(trust_path).read_text())
current = json.loads(pathlib.Path(current_path).read_text())
reasons = []
if not current.get("ready"):
    reasons.append("current_not_ready")
for key in ("generation", "service_token", "supervisor_pid", "supervisor_start_ticks"):
    if current.get(key) != trust.get(key):
        reasons.append(f"{key}_changed")
if int(current.get("backend_count", -1)) != expected:
    reasons.append("backend_count_changed")
if int(current.get("active_backend_count", -1)) != expected:
    reasons.append("active_backend_count_changed")
trust_backends = {item["application_name"]: item for item in trust.get("backends", [])}
current_backends = {item["application_name"]: item for item in current.get("backends", [])}
if set(trust_backends) != set(current_backends):
    reasons.append("backend_roster_changed")
else:
    for name, before in trust_backends.items():
        after = current_backends[name]
        for key in ("pid", "backend_start", "query_start", "xact_start", "user", "database"):
            if after.get(key) != before.get(key):
                reasons.append(f"{name}_{key}_changed")
                break
trust_bytes = int(trust.get("total_output_bytes", 0))
current_bytes = int(current.get("total_output_bytes", 0))
if require_progress and current_bytes <= trust_bytes + 1024:
    reasons.append("output_progress_not_advanced")
if reasons:
    print(
        "PEER_OK=0 "
        f"REASON={','.join(reasons[:6])} "
        f"TRUST_BYTES={trust_bytes} CURRENT_BYTES={current_bytes} "
        f"BACKENDS={current.get('backend_count')} ACTIVE={current.get('active_backend_count')}"
    )
    raise SystemExit(1)
print(
    "PEER_OK=1 "
    f"SUPERVISOR_PID={current.get('supervisor_pid')} "
    f"BACKENDS={current.get('backend_count')} ACTIVE={current.get('active_backend_count')} "
    f"TRUST_BYTES={trust_bytes} CURRENT_BYTES={current_bytes}"
)
PY
