#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
. "$TOPOLOGY_ENV"
[ "$(id -u)" = 0 ] || { echo "TRUST_OK=0 reason=root_required"; exit 1; }
bash "$ROOT/a/status_a.sh" >/dev/null
pid=$(<"$A_PID_FILE")
python3 - "$pid" "$A_PROGRAM" "$A_STATE_ROOT/status.json" "$A_TRUST_PATH" "$TOPOLOGY_ENV" "$A_CPU" "$AGENT_UID" <<'PY'
import hashlib, json, os, pathlib, sys, tempfile
pid, program, status_name, output_name, topology_name, expected_cpu, expected_uid = sys.argv[1:]
pid, expected_cpu, expected_uid = int(pid), int(expected_cpu), int(expected_uid)
program, status_path, output, topology_path = map(pathlib.Path, (program, status_name, output_name, topology_name))
stat = pathlib.Path(f"/proc/{pid}/stat").read_text(); tail = stat[stat.rfind(")") + 2:].split()
cmdline = pathlib.Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace")
status = json.loads(status_path.read_text())
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
cg_rel = next(line.split(":", 2)[2] for line in pathlib.Path("/proc/self/cgroup").read_text().splitlines() if line.startswith("0:"))
cg = pathlib.Path("/sys/fs/cgroup") / cg_rel.lstrip("/")
value = {
    "pid": pid, "uid": pathlib.Path(f"/proc/{pid}").stat().st_uid,
    "start_time_ticks": int(tail[19]), "process_group": int(tail[2]), "state": tail[0],
    "comm": pathlib.Path(f"/proc/{pid}/comm").read_text().strip(), "cmdline": cmdline,
    "affinity": sorted(os.sched_getaffinity(pid)), "expected_cpu": expected_cpu,
    "program_sha256": digest(program), "topology_sha256": digest(topology_path),
    "cpu_max": (cg / "cpu.max").read_text().strip(), "captured_unit": int(status["unit"]),
}
assert value["uid"] == expected_uid and value["affinity"] == [expected_cpu] and str(program) in cmdline
output.parent.mkdir(parents=True, exist_ok=True)
fd, temporary = tempfile.mkstemp(prefix=".trust.", dir=output.parent)
with os.fdopen(fd, "w") as handle:
    json.dump(value, handle, sort_keys=True, indent=2); handle.write("\n"); handle.flush(); os.fsync(handle.fileno())
os.chmod(temporary, 0o600); os.replace(temporary, output)
print(f"TRUST_OK=1 pid={pid} uid={value['uid']} start={value['start_time_ticks']} pgid={value['process_group']} cpu={expected_cpu} unit={value['captured_unit']}")
PY
