#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "$0")/../fixture.env"

rm -rf "$A_STATE_DIR"
install -d -o "$SERVICE_UID" -g "$SERVICE_GID" -m 700 "$A_STATE_DIR"
install -d -o "$SERVICE_UID" -g "$SERVICE_GID" -m 755 "$(dirname "$A_PROGRAM")"

setsid runuser -u "$SERVICE_USER" -- python3 - \
  --state-dir "$A_STATE_DIR" \
  --state-mib "$A_STATE_MIB" \
  <"$A_PROGRAM" \
  >"$A_LOG_FILE" 2>&1 &
pid=$!
printf '%s\n' "$pid" > "$A_PID_FILE.launcher"

python3 - "$A_STATE_FILE" "$A_READY_SEQUENCE" "$A_MIN_RSS_KIB" "$A_MIN_PSS_KIB" "$A_READY_TIMEOUT_SECONDS" <<'PY'
import json
import pathlib
import sys
import time

state_path = pathlib.Path(sys.argv[1])
ready_sequence = int(sys.argv[2])
min_rss = int(sys.argv[3])
min_pss = int(sys.argv[4])
deadline = time.monotonic() + int(sys.argv[5])
last = {}
while time.monotonic() < deadline:
    try:
        last = json.loads(state_path.read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        time.sleep(0.25)
        continue
    if last.get("phase") == "failed":
        raise SystemExit(f"A failed during startup: {last}")
    if (
        int(last.get("sequence", 0)) >= ready_sequence
        and int(last.get("rss_kib", 0)) >= min_rss
        and int(last.get("pss_kib", 0)) >= min_pss
    ):
        raise SystemExit(0)
    time.sleep(0.25)
raise SystemExit(f"A did not reach ready resident floor: {last}")
PY

state=$(python3 - "$A_STATE_FILE" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print(
    f"pid={data['pid']} starttime={data['starttime']} sequence={data['sequence']} "
    f"rss_kib={data['rss_kib']} pss_kib={data['pss_kib']} processed_edges={data['processed_edges']}"
)
PY
)

echo "A_STARTED $state state_dir=$A_STATE_DIR log=$A_LOG_FILE"
