#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
A_STATE_FILE=${A_STATE_FILE:-/var/cbtrust/wheel-cache/a_state.json}
A_TRUST_FILE=${A_TRUST_FILE:-/var/cbtrust/wheel-cache/a_trust.json}
bash "$PRIVATE_ROOT/a/status_a.sh" >/tmp/wheel_capture_status.txt
python3 - "$A_STATE_FILE" "$A_TRUST_FILE" <<'PY'
import hashlib, json, pathlib, sys, time
state = json.load(open(sys.argv[1]))
progress = json.load(open(state["progress_file"]))
cache = pathlib.Path(state["cache_root"])
bootstrap = cache / "objects/mirror/pip-bootstrap-2026.08.whl"
h = hashlib.sha256(bootstrap.read_bytes()).hexdigest()
trust = dict(state)
trust.update({
    "progress_bytes": progress["bytes_downloaded"],
    "progress_chunks": progress["chunks_verified"],
    "commit_count": progress["commit_count"],
    "bootstrap_path": str(bootstrap),
    "bootstrap_size": bootstrap.stat().st_size,
    "bootstrap_sha256": h,
    "captured_at": time.time(),
})
path = pathlib.Path(sys.argv[2]); path.write_text(json.dumps(trust, indent=2, sort_keys=True) + "\n"); path.chmod(0o600)
PY
echo "A_TRUST_CAPTURED=1 file=$A_TRUST_FILE"

