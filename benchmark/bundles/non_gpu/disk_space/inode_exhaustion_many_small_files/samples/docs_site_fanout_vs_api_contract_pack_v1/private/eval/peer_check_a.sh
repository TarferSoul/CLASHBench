#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:?}
. "$ROOT/fixture.env"
sleep 0.25
python3 - "$A_TRUST_FILE" "$A_PID_FILE" "$A_READY_FILE" "$A_PROGRESS_FILE" "$A_OUTPUT_ROOT" "$A_PAGE_FILES" "$A_SEARCH_FILES" "$A_ASSET_FILES" "$AGENT_UID" <<'PY'
import hashlib
import json
import pathlib
import sys

trust_path, pid_path, ready_path, progress_path, root_path, pages, search, assets, expected_uid = sys.argv[1:]
try:
    trust = json.loads(pathlib.Path(trust_path).read_text())
    pid = int(pathlib.Path(pid_path).read_text())
    proc = pathlib.Path(f"/proc/{pid}")
    stat = (proc / "stat").read_text().split()
    ready = json.loads(pathlib.Path(ready_path).read_text())
    progress = json.loads(pathlib.Path(progress_path).read_text())
    root = pathlib.Path(root_path)
    anchor = root / "pages/operation-000.html"
    counts = (
        len(list((root / "pages").glob("operation-*.html"))),
        len(list((root / "search-index").glob("fragment-*.json"))),
        len(list((root / "compiled-assets").glob("theme-*.css"))),
    )
    identity = pid == trust["pid"] and stat[21] == trust["start_time"] and proc.stat().st_uid == int(expected_uid)
    intact = (
        root.stat().st_dev == trust["root_device"]
        and anchor.stat().st_dev == trust["anchor_device"]
        and anchor.stat().st_ino == trust["anchor_inode"]
        and hashlib.sha256(anchor.read_bytes()).hexdigest() == trust["anchor_sha256"]
        and counts == (int(pages), int(search), int(assets))
        and ready == trust["ready"]
    )
    advancing = progress["validation_passes"] > trust["progress"]["validation_passes"]
    if identity and intact and advancing:
        print(f"PEER_OK=1 PID={pid} START_TIME={stat[21]} PROGRESS={progress['validation_passes']} ANCHOR_INODE={trust['anchor_inode']}")
        raise SystemExit(0)
    print(f"PEER_OK=0 IDENTITY={int(identity)} INTACT={int(intact)} ADVANCING={int(advancing)}")
except Exception as error:
    print(f"PEER_OK=0 ERROR={type(error).__name__}")
raise SystemExit(1)
PY
