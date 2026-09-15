#!/bin/bash
set -euo pipefail

: "${PRIVATE_CASE:?}"
: "${RESULT_ROOT:?}"
. "$PRIVATE_CASE/fixture.env"

mkdir -p /var/cbtrust
chmod 700 /var/cbtrust
trust="/var/cbtrust/io_bandwidth_${A_USER}_trust.json"
pid=$(cat "$A_RUNTIME_ROOT/pid")
state="$A_RUNTIME_ROOT/state.json"
latest="$A_RUNTIME_ROOT/checkpoints/latest"
start_time=$(awk '{print $22}' "/proc/$pid/stat")
pgrp=$(awk '{print $5}' "/proc/$pid/stat")
write_bytes=$(awk '/write_bytes:/ {print $2}' "/proc/$pid/io" 2>/dev/null || echo 0)
manifest=""
if [ -L "$latest" ]; then
  manifest="$A_RUNTIME_ROOT/checkpoints/$(readlink "$latest")/manifest.json"
fi
state_sha=$(sha256sum "$state" | awk '{print $1}')
manifest_sha=""
if [ -n "$manifest" ] && [ -f "$manifest" ]; then
  manifest_sha=$(sha256sum "$manifest" | awk '{print $1}')
fi
python3 - "$trust" "$pid" "$start_time" "$pgrp" "$write_bytes" "$state" "$state_sha" "$manifest" "$manifest_sha" <<'PY'
import json, pathlib, sys, time
out, pid, start, pgrp, write_bytes, state_path, state_sha, manifest, manifest_sha = sys.argv[1:]
state = json.loads(pathlib.Path(state_path).read_text())
payload = {
    "pid": int(pid),
    "start_time": start,
    "pgrp": pgrp,
    "write_bytes": int(write_bytes),
    "state_path": state_path,
    "state_sha256": state_sha,
    "generation": int(state.get("generation") or 0),
    "embedding_batches": int(state.get("embedding_batches") or 0),
    "phase": state.get("phase"),
    "manifest": manifest,
    "manifest_sha256": manifest_sha,
    "captured_at": time.time()
}
pathlib.Path(out).write_text(json.dumps(payload, indent=2) + "\n")
print(json.dumps(payload, sort_keys=True))
PY
