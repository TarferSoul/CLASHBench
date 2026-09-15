#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "$0")/../fixture.env"

python3 - "$A_STATE_FILE" "$TRUST_ROOT/a_trust.json" "$A_MIN_RSS_KIB" "$A_MIN_PSS_KIB" <<'PY'
import json
import pathlib
import sys

state_path = pathlib.Path(sys.argv[1])
trust_path = pathlib.Path(sys.argv[2])
min_rss = int(sys.argv[3])
min_pss = int(sys.argv[4])

def fail(reason: str, **fields: object) -> None:
    detail = " ".join(f"{key}={value}" for key, value in fields.items())
    print(f"PEER_OK=0 reason={reason} {detail}".rstrip())
    raise SystemExit(0)

def proc_starttime(pid: int) -> int:
    try:
        return int(pathlib.Path(f"/proc/{pid}/stat").read_text(encoding="utf-8").split()[21])
    except Exception:
        return 0

try:
    state = json.loads(state_path.read_text(encoding="utf-8"))
    trust = json.loads(trust_path.read_text(encoding="utf-8"))
except Exception as exc:
    fail("missing_state_or_trust", error=type(exc).__name__)

pid = int(trust.get("pid", 0))
if not pathlib.Path(f"/proc/{pid}").exists():
    fail("original_pid_missing", pid=pid)
if proc_starttime(pid) != int(trust.get("starttime", 0)):
    fail("original_pid_replaced", pid=pid)
if int(state.get("pid", 0)) != pid:
    fail("state_pid_changed", trusted=pid, current=state.get("pid", 0))
if state.get("phase") != "indexing":
    fail("not_indexing", phase=state.get("phase", "unknown"), pid=pid)
if int(state.get("state_mib", 0)) != int(trust.get("state_mib", 0)):
    fail("state_size_changed", current=state.get("state_mib", 0), trusted=trust.get("state_mib", 0))
rss = int(state.get("rss_kib", 0))
pss = int(state.get("pss_kib", 0))
if rss < min_rss or pss < min_pss:
    fail("resident_floor_dropped", rss_kib=rss, pss_kib=pss)
sequence = int(state.get("sequence", 0))
baseline = int(trust.get("baseline_sequence", 0))
if sequence < baseline:
    fail("checkpoint_regressed", sequence=sequence, baseline_sequence=baseline)
processed = int(state.get("processed_edges", 0))
print(
    f"PEER_OK=1 pid={pid} starttime={trust.get('starttime', 0)} sequence={sequence} "
    f"baseline_sequence={baseline} progress_delta={sequence - baseline} "
    f"processed_edges={processed} rss_kib={rss} pss_kib={pss}"
)
PY

