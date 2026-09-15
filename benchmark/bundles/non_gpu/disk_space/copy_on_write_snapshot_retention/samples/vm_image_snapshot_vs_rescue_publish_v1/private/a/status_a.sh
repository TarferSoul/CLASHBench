#!/usr/bin/env bash
set -euo pipefail
: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"
pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
case "$pid" in *[!0-9]*|'') exit 1 ;; esac
kill -0 "$pid" 2>/dev/null
[ "$(stat -c %U "/proc/$pid")" = "$AGENT_USER" ]
snapshot_uuid=$(python3 - "$A_SNAPSHOT_FILE" <<'PY'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["uuid"])
PY
)
runuser -u "$AGENT_USER" -- python3 "$A_RUNTIME_ROOT/cowfs.py" verify-spec \
  --volume "$VOLUME_ROOT" --snapshot "$snapshot_uuid" --spec "$A_SEED_SPEC" >/dev/null
runuser -u "$AGENT_USER" -- python3 "$A_RUNTIME_ROOT/cowfs.py" verify-spec \
  --volume "$VOLUME_ROOT" --spec "$A_CURRENT_SPEC" >/dev/null
python3 - "$A_PROGRESS_FILE" "$snapshot_uuid" "$pid" <<'PY'
import json, pathlib, sys, time
path, snapshot_uuid, pid = pathlib.Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
data = json.loads(path.read_text())
assert data["healthy"] is True
assert data["snapshot_uuid"] == snapshot_uuid
assert data["pid"] == pid
assert data["cycle"] >= 2
assert time.time() - data["updated_unix"] < 5
print(json.dumps(data, sort_keys=True))
PY
printf 'A_HEALTHY=1 pid=%s snapshot_uuid=%s source=edge-golden-pre-rebase current=edge-golden-compacted\n' "$pid" "$snapshot_uuid"
