#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
. "$CPU_ENV"
pid=$(cat "$A_RUN_ROOT/service.pid")
start_time=$(awk '{print $22}' "/proc/$pid/stat")
pgid=$(awk '{print $5}' "/proc/$pid/stat")
rss_kib=$(awk '/VmRSS:/{print $2}' "/proc/$pid/status")
allowed=$(awk '/Cpus_allowed_list:/{print $2}' "/proc/$pid/status")
[ "$allowed" = "$A_CPU" ] || { echo "A_TRUST_CAPTURED=0 reason=affinity_mismatch expected=$A_CPU actual=$allowed"; exit 1; }
pss_kib=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pss_kib"])' "$A_RUN_ROOT/health.json")
sequence=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sequence"])' "$A_RUN_ROOT/latest_checkpoint.json")
input_sha=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["input_sha256"])' "$A_RUN_ROOT/latest_checkpoint.json")
program_sha=$(sha256sum "$A_PROGRAM" | awk '{print $1}')
plan_sha=$(sha256sum "$A_PLAN_PATH" | awk '{print $1}')
cg_rel=$(awk -F: '$1=="0"{print $3}' /proc/self/cgroup)
cg="/sys/fs/cgroup/${cg_rel#/}"
python3 - "$A_TRUST_FILE" "$pid" "$start_time" "$pgid" "$rss_kib" "$pss_kib" "$sequence" "$input_sha" "$program_sha" "$plan_sha" "$cg" "$allowed" <<'PY'
import json
import pathlib
import sys
path, pid, start, pgid, rss, pss, sequence, input_sha, program_sha, plan_sha, cg, cpu = sys.argv[1:]
def read(name):
    return pathlib.Path(cg, name).read_text().strip()
payload = {"pid": int(pid), "start_time": start, "pgid": int(pgid), "rss_kib": int(rss), "pss_kib": int(pss), "sequence": int(sequence), "input_sha256": input_sha, "program_sha256": program_sha, "plan_sha256": plan_sha, "cpu": cpu, "memory_max": read("memory.max"), "memory_high": read("memory.high"), "swap_max": read("memory.swap.max"), "cpu_max": read("cpu.max"), "cpuset": read("cpuset.cpus.effective")}
out = pathlib.Path(path)
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
print(f"A_TRUST_CAPTURED=1 pid={pid} start_time={start} sequence={sequence} rss_kib={rss} pss_kib={pss}")
PY
chmod 600 "$A_TRUST_FILE"
