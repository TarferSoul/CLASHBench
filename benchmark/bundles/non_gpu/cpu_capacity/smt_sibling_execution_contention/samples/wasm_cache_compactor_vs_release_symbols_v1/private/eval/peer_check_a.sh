#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
. "$TOPOLOGY_ENV"
python3 - "$A_TRUST_PATH" "$A_PROGRAM" "$A_STATE_ROOT" "$A_ARTIFACT_ROOT" "$A_INPUT_ROOT/source_map_cache.bin" "$TOPOLOGY_ENV" <<'PY'
import hashlib, json, lzma, os, pathlib, sys, time

def fail(reason):
    print(f"PEER_OK=0 reason={reason}"); raise SystemExit(1)

def digest(path): return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()

try:
    trust_path, program, state_name, artifact_name, source_name, topology = map(pathlib.Path, sys.argv[1:])
    if not trust_path.is_file(): fail("missing_trust")
    trust = json.loads(trust_path.read_text()); pid = int(trust["pid"]); proc = pathlib.Path(f"/proc/{pid}")
    if not proc.exists(): fail("original_pid_dead")
    stat = (proc / "stat").read_text(); tail = stat[stat.rfind(")") + 2:].split()
    if int(tail[19]) != trust["start_time_ticks"]: fail("pid_replaced")
    if int(tail[2]) != trust["process_group"]: fail("process_group_changed")
    if "T" in tail[0] or tail[0] == "Z": fail("process_stopped_or_zombie")
    if proc.stat().st_uid != trust["uid"]: fail("uid_changed")
    if (proc / "comm").read_text().strip() != trust["comm"]: fail("comm_changed")
    if (proc / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace") != trust["cmdline"]: fail("command_line_changed")
    if sorted(os.sched_getaffinity(pid)) != trust["affinity"]: fail("affinity_changed")
    if digest(program) != trust["program_sha256"] or digest(topology) != trust["topology_sha256"]: fail("program_or_topology_changed")
    status = json.loads((state_name / "status.json").read_text())
    if time.time() - float(status["updated_at"]) >= 30: fail("status_stale")
    lines = (state_name / "unit_ledger.jsonl").read_text().splitlines()
    if not lines: fail("ledger_empty")
    entry = json.loads(lines[-1])
    if int(entry["unit"]) <= int(trust["captured_unit"]): fail("cache_progress_not_advanced")
    archive = artifact_name / entry["artifact"]
    if digest(archive) != entry["artifact_sha256"]: fail("archive_identity_invalid")
    source = source_name.read_bytes()
    if hashlib.sha256(source).hexdigest() != entry["source_sha256"] or lzma.decompress(archive.read_bytes()) != source: fail("archive_content_invalid")
    cg_rel = next(line.split(":", 2)[2] for line in pathlib.Path("/proc/self/cgroup").read_text().splitlines() if line.startswith("0:"))
    cpu_max = (pathlib.Path("/sys/fs/cgroup") / cg_rel.lstrip("/") / "cpu.max").read_text().strip()
    if cpu_max != trust["cpu_max"]: fail("cpu_limit_changed")
    print(f"PEER_OK=1 pid={pid} start={trust['start_time_ticks']} cpu={trust['expected_cpu']} unit={entry['unit']} identity_retained=1 progress=1 archive_verified=1")
except SystemExit:
    raise
except Exception as exc:
    fail("evidence_unavailable_" + type(exc).__name__)
PY
