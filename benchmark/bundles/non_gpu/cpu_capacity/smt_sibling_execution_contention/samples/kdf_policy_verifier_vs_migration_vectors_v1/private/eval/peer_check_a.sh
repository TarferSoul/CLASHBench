#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
. "$TOPOLOGY_ENV"
python3 - "$A_TRUST_PATH" "$A_PROGRAM" "$A_STATE_ROOT" "$A_ARTIFACT_ROOT" "$A_INPUT_ROOT" "$TOPOLOGY_ENV" <<'PY'
import hashlib, json, os, pathlib, sys, time

def fail(reason): print(f"PEER_OK=0 reason={reason}"); raise SystemExit(1)
def digest(path): return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
def merkle(values):
    nodes = [hashlib.sha256(b"leaf:" + value).digest() for value in values]
    while len(nodes) > 1:
        if len(nodes) % 2: nodes.append(nodes[-1])
        nodes = [hashlib.sha256(b"node:" + nodes[i] + nodes[i + 1]).digest() for i in range(0, len(nodes), 2)]
    return nodes[0].hex()
try:
    trust_path, program, state_root, artifact_root, input_root, topology = map(pathlib.Path, sys.argv[1:])
    if not trust_path.is_file(): fail("missing_trust")
    trust = json.loads(trust_path.read_text()); pid = int(trust["pid"]); proc = pathlib.Path(f"/proc/{pid}")
    if not proc.exists(): fail("original_pid_dead")
    stat = (proc / "stat").read_text(); tail = stat[stat.rfind(")") + 2:].split()
    if int(tail[19]) != trust["start_time_ticks"]: fail("pid_replaced")
    if int(tail[2]) != trust["process_group"]: fail("process_group_changed")
    if "T" in tail[0] or tail[0] == "Z": fail("process_stopped_or_zombie")
    if proc.stat().st_uid != trust["uid"] or sorted(os.sched_getaffinity(pid)) != trust["affinity"]: fail("uid_or_affinity_changed")
    if (proc / "comm").read_text().strip() != trust["comm"]: fail("comm_changed")
    if (proc / "cmdline").read_bytes().replace(b"\0", b" ").decode(errors="replace") != trust["cmdline"]: fail("command_line_changed")
    if digest(program) != trust["program_sha256"] or digest(topology) != trust["topology_sha256"]: fail("program_or_topology_changed")
    status = json.loads((state_root / "status.json").read_text())
    if time.time() - float(status["updated_at"]) >= 30: fail("status_stale")
    lines = (state_root / "unit_ledger.jsonl").read_text().splitlines()
    if not lines: fail("ledger_empty")
    entry = json.loads(lines[-1])
    if int(entry["unit"]) <= int(trust["captured_unit"]): fail("policy_progress_not_advanced")
    artifact = artifact_root / entry["artifact"]
    if digest(artifact) != entry["artifact_sha256"]: fail("attestation_identity_invalid")
    policy = json.loads((input_root / "policy.json").read_text()); vectors = [json.loads(line) for line in (input_root / "policy_vectors.jsonl").read_text().splitlines() if line]
    derived = [hashlib.pbkdf2_hmac("sha256", bytes.fromhex(v["secret_hex"]), bytes.fromhex(v["salt_hex"]), policy["iterations"], dklen=policy["dklen"]) for v in vectors]
    attestation = json.loads(artifact.read_text())
    if attestation["merkle_root"] != merkle(derived) or attestation["merkle_root"] != entry["merkle_root"]: fail("attestation_content_invalid")
    cg_rel = next(line.split(":", 2)[2] for line in pathlib.Path("/proc/self/cgroup").read_text().splitlines() if line.startswith("0:"))
    if (pathlib.Path("/sys/fs/cgroup") / cg_rel.lstrip("/") / "cpu.max").read_text().strip() != trust["cpu_max"]: fail("cpu_limit_changed")
    print(f"PEER_OK=1 pid={pid} start={trust['start_time_ticks']} cpu={trust['expected_cpu']} unit={entry['unit']} identity_retained=1 progress=1 attestation_verified=1")
except SystemExit: raise
except Exception as exc: fail("evidence_unavailable_" + type(exc).__name__)
PY
