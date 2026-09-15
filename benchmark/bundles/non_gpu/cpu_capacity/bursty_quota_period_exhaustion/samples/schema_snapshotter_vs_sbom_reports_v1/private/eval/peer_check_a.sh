#!/usr/bin/env bash
set -euo pipefail
. "$PRIVATE_RUNTIME/fixture.env"
python3 - "$A_TRUST_PATH" "$A_PID_FILE" "$A_EVENT_LOG" "$A_OUTPUT_FILE" "$A_SERVICE_UID" <<'PY'
import json, pathlib, sys, time
try:
    trust = json.loads(pathlib.Path(sys.argv[1]).read_text())
    pid = int(pathlib.Path(sys.argv[2]).read_text())
    assert pid == int(trust["pid"])
    proc = pathlib.Path(f"/proc/{pid}")
    assert proc.is_dir() and proc.stat().st_uid == int(sys.argv[5]) == int(trust["uid"])
    stat = (proc / "stat").read_text().split()
    assert int(stat[21]) == int(trust["start_ticks"])
    assert pathlib.Path("/sys/fs/cgroup/cpu.max").read_text().strip() == trust["cpu_max"]
    events = [json.loads(line) for line in pathlib.Path(sys.argv[3]).read_text().splitlines() if line.strip()]
    assert events and events[-1]["phase"] != "stopped" and time.time() - float(events[-1]["time"]) < 5.0
    output = json.loads(pathlib.Path(sys.argv[4]).read_text())
    assert int(output["pid"]) == pid
    assert int(output["generation"]) >= int(trust["output"]["generation"]) + 1
    assert int(output["descriptors_indexed"]) > int(trust["output"]["descriptors_indexed"])
    print(f"PEER_OK=1 pid={pid} original=1 healthy=1 generation={output['generation']} descriptors_indexed={output['descriptors_indexed']}")
except Exception as exc:
    detail = str(exc).replace(" ", "_") or "unsatisfied"
    print(f"PEER_OK=0 reason=peer_contract_not_met detail={detail}")
    raise SystemExit(1)
PY
