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
    for path in sorted(a_root.glob("*.layer")):
        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        stat = path.stat()
        current[path.name] = {"sha256": digest.hexdigest(), "size": stat.st_size, "inode": stat.st_ino, "device": stat.st_dev}
    layers_intact = current == trust["files"] and all(item["device"] == trust["volume_device"] for item in current.values())
    progressing = int(state.get("verification_passes", -1)) >= int(trust["verification_passes"]) and int(state.get("verified_bytes", -1)) >= int(trust["verified_bytes"])
    healthy = state.get("phase") == "verifying" and time.time_ns() - int(state.get("heartbeat_ns", 0)) < 3_000_000_000
    ok = original and layers_intact and progressing and healthy
except Exception as exc:
    print(f"PEER_OK=0 reason=inspection_error detail={type(exc).__name__}")
    raise SystemExit(1)
if ok:
    print(f"PEER_OK=1 pid={pid} original=1 healthy=1 layers_intact=1 device={trust['volume_device']} verification_passes={state['verification_passes']} verified_bytes={state['verified_bytes']}")
    raise SystemExit(0)
print(f"PEER_OK=0 pid={pid} original={int(original)} healthy={int(healthy)} layers_intact={int(layers_intact)} progressing={int(progressing)}")
raise SystemExit(1)
PY

