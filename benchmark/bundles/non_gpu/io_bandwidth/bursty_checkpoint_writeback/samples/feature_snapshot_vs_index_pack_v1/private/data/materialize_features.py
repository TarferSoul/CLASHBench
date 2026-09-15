#!/usr/bin/env python3
"""Run a bounded feature materialization job with durable snapshot phases."""
import concurrent.futures
import hashlib
import json
import os
import pathlib
import signal
import time

root = pathlib.Path(os.environ["A_WORK_ROOT"])
cycles = int(os.environ.get("A_CYCLES", "9")); continuous = os.environ.get("A_CONTINUOUS", "0") == "1"; shards = int(os.environ.get("CHECKPOINT_SHARDS", "8")); shard_mb = int(os.environ.get("CHECKPOINT_SHARD_MB", "48")); keep = int(os.environ.get("CHECKPOINT_KEEP", "2"))
gate_root = pathlib.Path(os.environ["A_PHASE_GATE_ROOT"]) if os.environ.get("A_PHASE_GATE_ROOT") else None
gate_from = int(os.environ.get("A_PHASE_GATE_FROM", "3")); gate_timeout = float(os.environ.get("A_PHASE_GATE_TIMEOUT", "20")); poll = float(os.environ.get("A_PHASE_POLL_SEC", "0.01")); pid = os.getpid(); stop_requested = False

def stop(_signum, _frame):
    global stop_requested
    stop_requested = True
signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop)
root.mkdir(parents=True, exist_ok=True)
for old in root.glob("snapshot-*"):
    if old.is_dir():
        for path in sorted(old.rglob("*"), reverse=True):
            if path.is_file() or path.is_symlink(): path.unlink()
            elif path.is_dir(): path.rmdir()
        old.rmdir()

def write_json(path, value):
    tmp = pathlib.Path(str(path) + ".tmp"); tmp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n"); os.replace(tmp, path)

status_path = root / "status.json"; history_path = root / "snapshot-manifest.json"
status = {"pid": pid, "phase": "starting", "snapshot_id": 0, "completed_snapshots": 0, "work_units": 0, "snapshot_bytes": 0}
write_json(status_path, status); write_json(history_path, {"pipeline": "feature-materialization", "snapshots": []})

snapshot_id = 0
while not stop_requested and (continuous or snapshot_id < cycles):
    snapshot_id += 1
    if stop_requested: break
    work_units = snapshot_id * 17; status.update({"phase": "aggregate", "snapshot_id": snapshot_id, "work_units": work_units}); write_json(status_path, status)
    digest = hashlib.sha256(f"feature-batch-{snapshot_id}".encode()).digest()
    for _ in range(5): digest = hashlib.sha256(digest + b"/feature-row").digest()
    time.sleep(0.035)
    status.update({"phase": "snapshot_prepare", "snapshot_id": snapshot_id}); write_json(status_path, status)
    if gate_root is not None and snapshot_id >= gate_from:
        gate_root.mkdir(parents=True, exist_ok=True); ready = gate_root / f"snapshot-{snapshot_id:03d}.ready"; release = gate_root / f"snapshot-{snapshot_id:03d}.release"; ready.write_text(f"pid={pid} snapshot={snapshot_id}\n")
        deadline = time.monotonic() + gate_timeout
        while not release.exists() and time.monotonic() < deadline and not stop_requested: time.sleep(poll)
    temp = root / f".snapshot-{snapshot_id:03d}.tmp"; final = root / f"snapshot-{snapshot_id:03d}"
    if temp.exists():
        for p in sorted(temp.rglob("*"), reverse=True):
            if p.is_file(): p.unlink()
            elif p.is_dir(): p.rmdir()
        temp.rmdir()
    temp.mkdir(); status.update({"phase": "snapshot_write", "snapshot_id": snapshot_id, "snapshot_bytes": 0}); write_json(status_path, status)
    pattern = (f"snapshot={snapshot_id};feature={digest.hex()};" + "f" * 1024).encode(); chunk_size = 1024 * 1024; chunk = (pattern * ((chunk_size // len(pattern)) + 1))[:chunk_size]
    def write_shard(shard):
        target = temp / f"features-{shard:02d}.bin"; hasher = hashlib.sha256()
        with open(target, "wb", buffering=0) as handle:
            for _ in range(shard_mb):
                handle.write(chunk); hasher.update(chunk)
            os.fdatasync(handle.fileno())
        return {"path": target.name, "bytes": target.stat().st_size, "sha256": hasher.hexdigest()}
    with concurrent.futures.ThreadPoolExecutor(max_workers=shards) as executor:
        records = list(executor.map(write_shard, range(shards)))
    total = sum(record["bytes"] for record in records); status["snapshot_bytes"] = total
    manifest = {"pipeline": "feature-materialization", "snapshot_id": snapshot_id, "complete": True, "files": records, "total_bytes": total}; write_json(temp / "snapshot.json", manifest)
    fd = os.open(temp, os.O_RDONLY); os.fsync(fd); os.close(fd); os.replace(temp, final)
    latest_tmp = root / "latest.tmp"; latest_tmp.unlink(missing_ok=True); os.symlink(final.name, latest_tmp); os.replace(latest_tmp, root / "latest")
    history = json.loads(history_path.read_text()); history["snapshots"].append({"snapshot_id": snapshot_id, "path": final.name, "total_bytes": total}); history["snapshots"] = history["snapshots"][-keep:]; write_json(history_path, history)
    published = sorted((path for path in root.glob("snapshot-*") if path.is_dir()), key=lambda path: int(path.name.rsplit("-", 1)[1]))
    for stale in published[:-max(keep, 16)]:
        for path in sorted(stale.rglob("*"), reverse=True):
            if path.is_file() or path.is_symlink(): path.unlink()
            elif path.is_dir(): path.rmdir()
        stale.rmdir()
    status.update({"phase": "snapshot_publish", "completed_snapshots": snapshot_id, "snapshot_bytes": total}); write_json(status_path, status); status.update({"phase": "aggregate", "work_units": work_units + 7}); write_json(status_path, status); time.sleep(0.025)
status["phase"] = "stopped" if stop_requested else "aggregate"; write_json(status_path, status)
