#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
python3 - "$A_TRUST_FILE" "$A_RUN_ROOT/health.json" "$A_RUN_ROOT/latest_checkpoint.json" "$A_PROGRAM" "$A_PLAN_PATH" "$A_RSS_FLOOR_KIB" "$A_SERVICE_USER" <<'PY'
import hashlib
import json
import pathlib
import sys
try:
    trust = json.loads(pathlib.Path(sys.argv[1]).read_text())
    health = json.loads(pathlib.Path(sys.argv[2]).read_text())
    checkpoint = json.loads(pathlib.Path(sys.argv[3]).read_text())
    program = pathlib.Path(sys.argv[4])
    plan = pathlib.Path(sys.argv[5])
    floor = int(sys.argv[6])
    _user = sys.argv[7]
    pid = int(trust["pid"])
    stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    assert stat[2] not in {"Z", "T"}
    assert stat[21] == trust["start_time"] and int(stat[4]) == int(trust["pgid"])
    status = pathlib.Path(f"/proc/{pid}/status").read_text()
    rss = int(status.split("VmRSS:", 1)[1].split()[0])
    allowed = status.split("Cpus_allowed_list:", 1)[1].split()[0]
    pss = int(health["pss_kib"])
    assert rss >= floor and pss >= floor
    assert hashlib.sha256(program.read_bytes()).hexdigest() == trust["program_sha256"]
    assert hashlib.sha256(plan.read_bytes()).hexdigest() == trust["plan_sha256"]
    assert allowed == trust["cpu"], f"affinity_changed expected={trust['cpu']} actual={allowed}"
    assert health["status"] == "ready" and health["input_valid"] is True
    assert checkpoint["input_valid"] is True and checkpoint["input_sha256"] == trust["input_sha256"]
    assert int(checkpoint["sequence"]) > int(trust["sequence"])
    rel = next(line.split(":", 2)[2] for line in pathlib.Path("/proc/self/cgroup").read_text().splitlines() if line.startswith("0:"))
    cg = pathlib.Path("/sys/fs/cgroup") / rel.lstrip("/")
    assert (cg / "memory.max").read_text().strip() == trust["memory_max"]
    assert (cg / "memory.high").read_text().strip() == trust["memory_high"]
    assert (cg / "memory.swap.max").read_text().strip() == trust["swap_max"]
    assert (cg / "cpu.max").read_text().strip() == trust["cpu_max"]
    assert (cg / "cpuset.cpus.effective").read_text().strip() == trust["cpuset"]
except Exception as exc:
    print(f"PEER_OK=0 reason=incumbent_health_or_identity_invalid type={type(exc).__name__}")
    raise SystemExit(1)
print(f"PEER_OK=1 pid={pid} start_time={trust['start_time']} sequence={checkpoint['sequence']} rss_kib={rss} pss_kib={pss}")
PY
