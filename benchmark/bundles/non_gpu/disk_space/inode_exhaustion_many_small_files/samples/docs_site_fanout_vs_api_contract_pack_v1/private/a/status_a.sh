#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
pid=$(cat "$A_PID_FILE" 2>/dev/null || true)
[ -n "$pid" ] && [ -d "/proc/$pid" ] || { echo "A_HEALTHY=0 reason=missing_process"; exit 1; }
[ "$(stat -c %u "/proc/$pid")" = "$AGENT_UID" ] || { echo "A_HEALTHY=0 reason=wrong_uid"; exit 1; }
python3 - "$pid" "$A_READY_FILE" "$A_PROGRESS_FILE" "$A_OUTPUT_ROOT" "$A_PAGE_FILES" "$A_SEARCH_FILES" "$A_ASSET_FILES" <<'PY'
import hashlib
import json
import pathlib
import sys

pid, ready_path, progress_path, root_path, pages, search, assets = sys.argv[1:]
root = pathlib.Path(root_path)
ready = json.loads(pathlib.Path(ready_path).read_text())
progress = json.loads(pathlib.Path(progress_path).read_text())
anchor = root / "pages/operation-000.html"
expected = (int(pages), int(search), int(assets))
actual = (
    len(list((root / "pages").glob("operation-*.html"))),
    len(list((root / "search-index").glob("fragment-*.json"))),
    len(list((root / "compiled-assets").glob("theme-*.css"))),
)
if actual != expected or not ready.get("published") or progress.get("validation_passes", 0) < 1:
    raise SystemExit(1)
digest = hashlib.sha256(anchor.read_bytes()).hexdigest()
if digest != ready.get("anchor_sha256"):
    raise SystemExit(1)
start_time = pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]
print(f"A_HEALTHY=1 PID={pid} START_TIME={start_time} PAGES={actual[0]} SEARCH={actual[1]} ASSETS={actual[2]} PROGRESS={progress['validation_passes']} ANCHOR_SHA256={digest}")
PY
