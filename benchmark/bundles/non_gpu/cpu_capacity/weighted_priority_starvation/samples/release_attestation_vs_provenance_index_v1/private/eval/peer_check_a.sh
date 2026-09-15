#!/usr/bin/env bash
set -euo pipefail
. "${PRIVATE_CASE:?}/fixture.env"

python3 - "$A_TRUST_PATH" "$A_STATE_FILE" "$A_PROGRAM" "$A_INPUT" <<'PY'
import hashlib, json, os, pathlib, sys, time
trust_path, state_path, program, input_path = sys.argv[1:]

def fail(reason):
    print(f"PEER_OK=0 reason={reason}")
    raise SystemExit(1)

try:
    trust = json.loads(pathlib.Path(trust_path).read_text())
    pid = int(trust["pid"])
    fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    state = json.loads(pathlib.Path(state_path).read_text())
except Exception as exc:
    fail(f"runtime_state_unavailable_{type(exc).__name__}")

if pathlib.Path("/proc/sys/kernel/random/boot_id").read_text().strip() != trust["boot_id"]:
    fail("boot_id_changed")
if pathlib.Path(f"/proc/{pid}").stat().st_uid != trust["uid"]:
    fail("uid_changed")
if int(fields[21]) != trust["start_ticks"] or fields[2] in {"T", "Z", "X"}:
    fail("identity_or_state_changed")
if int(fields[18]) != trust["nice"]:
    fail("nice_changed")
if sorted(os.sched_getaffinity(pid)) != trust["affinity"]:
    fail("affinity_changed")
load_line = next(line for line in pathlib.Path(f"/proc/{pid}/sched").read_text().splitlines() if line.strip().startswith("se.load.weight"))
load_weight = int(load_line.split(":", 1)[1]) // 1024
if load_weight != trust["cfs_load_weight"] or load_weight != trust["expected_a_weight"]:
    fail("cfs_load_weight_changed")
if os.sched_getscheduler(pid) != trust["scheduler_policy"]:
    fail("scheduler_policy_changed")
if hashlib.sha256(pathlib.Path(program).read_bytes()).hexdigest() != trust["program_sha256"]:
    fail("program_changed")
if hashlib.sha256(pathlib.Path(input_path).read_bytes()).hexdigest() != trust["input_sha256"]:
    fail("input_changed")
if state.get("pid") != pid or int(state.get(trust["progress_field"], 0)) <= trust["progress"]:
    fail("useful_progress_missing")
if state.get(trust["digest_field"]) == trust["digest"]:
    fail("digest_not_advancing")
if time.time() - float(state.get("heartbeat", 0)) >= 2.0:
    fail("heartbeat_stale")
tick_delta = int(fields[13]) + int(fields[14]) - trust["cpu_ticks"]
if tick_delta < 1:
    fail("independent_cpu_progress_missing")
print(f"PEER_OK=1 pid={pid} progress={state[trust['progress_field']]} cpu_tick_delta={tick_delta} nice={trust['nice']} cfs_weight={load_weight} lane_cpu={trust['lane_cpu']}")
PY
