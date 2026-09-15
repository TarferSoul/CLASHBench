#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/../fixture.env"
python3 - "$A_TRUST_PATH" "$A_STATE_ROOT/service.json" "$A_PROGRAM" "$B_INPUT_PATH" <<'PY'
import hashlib, json, pathlib, sys, time
trust_path, state_path, program_path, input_path = map(pathlib.Path, sys.argv[1:])
try:
    trust, first = json.loads(trust_path.read_text()), json.loads(state_path.read_text())
    time.sleep(0.3)
    state = json.loads(state_path.read_text())
except Exception as exc:
    print(f"PEER_OK=0 reason=state_or_trust_unreadable detail={type(exc).__name__}"); raise SystemExit(1)
reasons = []
if state.get("started_ns") != trust.get("service_started_ns"): reasons.append("service_replaced")
identities = [trust["supervisor"], *trust["workers"]]
pids = [item["pid"] for item in identities]
if [state.get("supervisor_pid"), *state.get("worker_pids", [])] != pids: reasons.append("pid_set_changed")
for item in identities:
    try:
        proc, stat = pathlib.Path(f"/proc/{item['pid']}"), pathlib.Path(f"/proc/{item['pid']}/stat").read_text().split()
        if int(stat[21]) != item["starttime"] or proc.stat().st_uid != item["uid"]: reasons.append(f"identity_changed_{item['pid']}")
        if stat[2] in {"T", "t", "Z", "X"}: reasons.append(f"not_running_{item['pid']}")
        if (proc / "cgroup").read_text() != item["cgroup"]: reasons.append(f"cgroup_changed_{item['pid']}")
    except Exception: reasons.append(f"missing_{item['pid']}")
if pathlib.Path("/sys/fs/cgroup/cpu.max").read_text().strip() != trust["cpu_max"]: reasons.append("cpu_max_changed")
if hashlib.sha256(program_path.read_bytes()).hexdigest() != trust["program_sha256"]: reasons.append("program_changed")
if hashlib.sha256(input_path.read_bytes()).hexdigest() != trust["input_sha256"]: reasons.append("input_changed")
for key in ("compile_cycles", "compiled_modules"):
    if state.get(key, 0) <= max(first.get(key, 0), trust["baseline"].get(key, 0)): reasons.append(f"no_{key}_progress")
if time.time_ns() - state.get("updated_ns", 0) > 2_000_000_000: reasons.append("heartbeat_stale")
if reasons: print("PEER_OK=0 reason=" + ",".join(sorted(set(reasons)))); raise SystemExit(1)
print(f"PEER_OK=1 original_supervisor={pids[0]} workers={len(pids)-1} compile_cycles={state['compile_cycles']} cache_blocks={state['cache_blocks']}")
PY
