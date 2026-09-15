#!/usr/bin/env python3
import hashlib
import json
import os
import pathlib
import queue
import signal
import threading
import time

from artifact_io import atomic_json, direct_sample_read, parse_safetensors_header, process_start_time, read_proc_io, stat_identity, tensor_prefix_digest


RUNNING = True


def handle_signal(signum, frame):
    global RUNNING
    RUNNING = False


signal.signal(signal.SIGTERM, handle_signal)
signal.signal(signal.SIGINT, handle_signal)


def env_int(name, default):
    return int(os.environ.get(name, default))


def load_index(root):
    path = pathlib.Path(root) / "shard_index.json"
    data = json.loads(path.read_text())
    return path, data, hashlib.sha256(path.read_bytes()).hexdigest()


def write_heartbeat(state_root, payload):
    atomic_json(pathlib.Path(state_root) / "heartbeat.json", {"time": time.time(), **payload})


def main():
    checkpoint_id = os.environ["CHECKPOINT_ID"]
    root = pathlib.Path(os.environ["A_VISIBLE_ROOT"])
    state_root = pathlib.Path(os.environ["A_STATE_ROOT"])
    stream_count = max(1, env_int("A_DIRECT_STREAMS", 1))
    block_bytes = env_int("DIRECT_BLOCK_BYTES", 4 * 1024 * 1024)
    sample_bytes = env_int("HASH_SAMPLE_BYTES", 4096)
    state_root.mkdir(parents=True, exist_ok=True)
    index_path, index, index_digest = load_index(root)
    work = queue.Queue()
    lock = threading.Lock()
    counters = {
        "audited_shard_count": 0,
        "audited_bytes": 0,
        "tensor_count": 0,
        "cycles": 0,
        "errors": 0,
        "current_shard": "",
        "last_sample_sha256": "",
    }
    pid = os.getpid()
    start_time = process_start_time(pid)
    pgid = os.getpgid(pid)

    def status(extra=None):
        proc_io = read_proc_io()
        payload = {
            "pid": pid,
            "start_time": start_time,
            "pgid": pgid,
            "checkpoint_id": checkpoint_id,
            "index_path": str(index_path),
            "index_digest": index_digest,
            "direct_read": True,
            "stream_count": stream_count,
            "process_read_bytes": proc_io.get("read_bytes", 0),
            "process_rchar": proc_io.get("rchar", 0),
            "artifact_identity": stat_identity(root),
            **counters,
        }
        if extra:
            payload.update(extra)
        atomic_json(state_root / "status.json", payload)
        write_heartbeat(state_root, {"pid": pid, "audited_bytes": counters["audited_bytes"], "current_shard": counters["current_shard"]})

    def audit_one(shard):
        nonlocal counters
        path = pathlib.Path(shard["path"])
        parsed = parse_safetensors_header(path)
        if len(parsed["tensors"]) != int(shard["tensor_count"]):
            raise ValueError(f"{path} tensor count mismatch")
        read = direct_sample_read(path, block_bytes, sample_bytes, require_direct=True)
        if read["sample_sha256"] != shard["block_sample_sha256"]:
            raise ValueError(f"{path} sample digest mismatch")
        for name, expected in shard["tensor_prefix_sha256"].items():
            offset = parsed["tensors"][name]["data_offsets"][0]
            actual = tensor_prefix_digest(path, parsed["data_start"], offset, min(sample_bytes, 4096))
            if actual != expected:
                raise ValueError(f"{path} tensor prefix mismatch {name}")
        with lock:
            counters["audited_shard_count"] += 1
            counters["audited_bytes"] += int(read["bytes"])
            counters["tensor_count"] += len(parsed["tensors"])
            counters["current_shard"] = shard["shard_id"]
            counters["last_sample_sha256"] = read["sample_sha256"]
            if counters["audited_shard_count"] % len(index["shards"]) == 0:
                counters["cycles"] += 1
            status()

    def worker(worker_index):
        while RUNNING:
            try:
                shard = work.get(timeout=0.2)
            except queue.Empty:
                continue
            try:
                audit_one(shard)
            except Exception as exc:
                with lock:
                    counters["errors"] += 1
                    status({"last_error": str(exc), "worker_index": worker_index})
                time.sleep(0.2)
            finally:
                work.task_done()

    for _ in range(stream_count * 2):
        for shard in index["shards"]:
            work.put(shard)
    threads = [threading.Thread(target=worker, args=(idx,), daemon=True) for idx in range(stream_count)]
    for thread in threads:
        thread.start()
    status({"started_at": time.time()})
    while RUNNING:
        if work.qsize() < len(index["shards"]):
            for shard in index["shards"]:
                work.put(shard)
        status()
        time.sleep(0.25)
    status({"stopping": True})


if __name__ == "__main__":
    main()
