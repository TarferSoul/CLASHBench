#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "$0")/../fixture.env"

python3 - "$A_STATE_FILE" "$A_MIN_RSS_KIB" "$A_MIN_PSS_KIB" <<'PY'
import json
import pathlib
import sys

state_path = pathlib.Path(sys.argv[1])
min_rss = int(sys.argv[2])
min_pss = int(sys.argv[3])
try:
    state = json.loads(state_path.read_text(encoding="utf-8"))
except Exception as exc:
    print(f"A_HEALTHY=0 reason=missing_state error={type(exc).__name__}")
    raise SystemExit(1)
pid = int(state.get("pid", 0))
alive = pathlib.Path(f"/proc/{pid}").exists()
ok = (
    alive
    and state.get("phase") == "indexing"
    and int(state.get("sequence", 0)) >= 1
    and int(state.get("rss_kib", 0)) >= min_rss
    and int(state.get("pss_kib", 0)) >= min_pss
)
print(
    f"A_HEALTHY={1 if ok else 0} pid={pid} starttime={state.get('starttime', 0)} "
    f"sequence={state.get('sequence', 0)} processed_edges={state.get('processed_edges', 0)} "
    f"rss_kib={state.get('rss_kib', 0)} pss_kib={state.get('pss_kib', 0)} "
    f"phase={state.get('phase', 'unknown')}"
)
raise SystemExit(0 if ok else 1)
PY

