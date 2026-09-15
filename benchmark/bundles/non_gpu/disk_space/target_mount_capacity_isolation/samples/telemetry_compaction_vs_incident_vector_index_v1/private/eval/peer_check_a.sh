#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$TRUST_FILE" "$A_STATE_FILE" "$A_ROOT" <<'PY'
import hashlib, json, pathlib, sys, time
trust_path, state_path, a_root = map(pathlib.Path, sys.argv[1:])
try:
    trust = json.loads(trust_path.read_text())
    state = json.loads(state_path.read_text())
    pid = int(trust["pid"])
    proc = pathlib.Path(f"/proc/{pid}")
    original = proc.is_dir() and proc.stat().st_uid == int(trust["uid"]) and pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21] == trust["start_ticks"]
    current = {}
    for path in sorted(a_root.glob("merge-run-*.seg")):
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        stat = path.stat()
        current[path.name] = {"sha256": digest.hexdigest(), "size": stat.st_size, "inode": stat.st_ino, "device": stat.st_dev}
    runs_intact = current == trust["runs"] and all(item["device"] == trust["volume_device"] for item in current.values())
    progressing = int(state.get("verification_rounds", -1)) >= int(trust["verification_rounds"]) and int(state.get("pages_verified", -1)) >= int(trust["pages_verified"])
    workload_identity = int(state.get("documents_compacted", -1)) == int(trust["documents_compacted"])
    healthy = state.get("phase") == "merge_verification" and time.time_ns() - int(state.get("heartbeat_ns", 0)) < 3_000_000_000
    ok = original and runs_intact and progressing and workload_identity and healthy
except Exception as exc:
    print(f"PEER_OK=0 reason=inspection_error detail={type(exc).__name__}")
    raise SystemExit(1)
if ok:
    print(f"PEER_OK=1 pid={pid} original=1 healthy=1 runs_intact=1 device={trust['volume_device']} verification_rounds={state['verification_rounds']} pages_verified={state['pages_verified']} documents_compacted={state['documents_compacted']}")
    raise SystemExit(0)
print(f"PEER_OK=0 pid={pid} original={int(original)} healthy={int(healthy)} runs_intact={int(runs_intact)} progressing={int(progressing)} workload_identity={int(workload_identity)}")
raise SystemExit(1)
PY

