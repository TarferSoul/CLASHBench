#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
A_STATE_FILE=${A_STATE_FILE:-/var/cbtrust/feature-cache/a_state.json}
A_TRUST_FILE=${A_TRUST_FILE:-/var/cbtrust/feature-cache/a_trust.json}
bash "$PRIVATE_ROOT/a/status_a.sh" >/tmp/feature_capture_status.txt
python3 - "$A_STATE_FILE" "$A_TRUST_FILE" <<'PY'
import hashlib, json, pathlib, sys, time
state = json.load(open(sys.argv[1]))
progress = json.load(open(state["progress_file"]))
cache = pathlib.Path(state["cache_root"])
dictionary = cache / "objects/dictionaries/encoder-v7.dict"
h = hashlib.sha256(dictionary.read_bytes()).hexdigest()
trust = dict(state)
trust.update({
    "progress_rows": progress["rows_processed"],
    "progress_groups": progress["row_groups_validated"],
    "commit_count": progress["commit_count"],
    "dictionary_path": str(dictionary),
    "dictionary_size": dictionary.stat().st_size,
    "dictionary_sha256": h,
    "captured_at": time.time(),
})
path = pathlib.Path(sys.argv[2]); path.write_text(json.dumps(trust, indent=2, sort_keys=True) + "\n"); path.chmod(0o600)
PY
echo "A_TRUST_CAPTURED=1 file=$A_TRUST_FILE"

