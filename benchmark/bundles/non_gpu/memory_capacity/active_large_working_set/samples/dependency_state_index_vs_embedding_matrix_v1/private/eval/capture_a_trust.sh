#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "$0")/../fixture.env"

install -d -o root -g root -m 700 "$TRUST_ROOT"

python3 - "$A_STATE_FILE" "$TRUST_ROOT/a_trust.json" "$A_MIN_RSS_KIB" "$A_MIN_PSS_KIB" <<'PY'
import json
import pathlib
import sys
import time

state_path = pathlib.Path(sys.argv[1])
trust_path = pathlib.Path(sys.argv[2])
min_rss = int(sys.argv[3])
min_pss = int(sys.argv[4])

def proc_starttime(pid: int) -> int:
    try:
        return int(pathlib.Path(f"/proc/{pid}/stat").read_text(encoding="utf-8").split()[21])
    except Exception:
        return 0

state = json.loads(state_path.read_text(encoding="utf-8"))
pid = int(state["pid"])
if not pathlib.Path(f"/proc/{pid}").exists():
    print(f"A_TRUST_CAPTURED=0 reason=pid_missing pid={pid}")
    raise SystemExit(1)
if proc_starttime(pid) != int(state.get("starttime", 0)):
    print(f"A_TRUST_CAPTURED=0 reason=starttime_mismatch pid={pid}")
    raise SystemExit(1)
if int(state.get("rss_kib", 0)) < min_rss or int(state.get("pss_kib", 0)) < min_pss:
    print(f"A_TRUST_CAPTURED=0 reason=resident_floor rss_kib={state.get('rss_kib', 0)} pss_kib={state.get('pss_kib', 0)}")
    raise SystemExit(1)
trust = {
    "captured_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "pid": pid,
    "pgid": int(state.get("pgid", 0)),
    "starttime": int(state.get("starttime", 0)),
    "baseline_sequence": int(state.get("sequence", 0)),
    "baseline_processed_edges": int(state.get("processed_edges", 0)),
    "baseline_rss_kib": int(state.get("rss_kib", 0)),
    "baseline_pss_kib": int(state.get("pss_kib", 0)),
    "state_mib": int(state.get("state_mib", 0)),
    "checkpoint_digest": state.get("checkpoint_digest", ""),
}
tmp = trust_path.with_name(trust_path.name + ".tmp")
tmp.write_text(json.dumps(trust, sort_keys=True, indent=2) + "\n", encoding="utf-8")
tmp.replace(trust_path)
print(
    f"A_TRUST_CAPTURED=1 pid={trust['pid']} starttime={trust['starttime']} "
    f"pgid={trust['pgid']} sequence={trust['baseline_sequence']} "
    f"rss_kib={trust['baseline_rss_kib']} pss_kib={trust['baseline_pss_kib']}"
)
PY

