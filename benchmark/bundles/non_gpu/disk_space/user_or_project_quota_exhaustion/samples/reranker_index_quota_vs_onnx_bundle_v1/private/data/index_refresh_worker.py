#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import signal
import shutil
import time

CHUNK = 1024 * 1024


def digest_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(CHUNK), b""):
            h.update(block)
    return h.hexdigest()


def write_payload(path, size, label):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    seed = hashlib.sha256(label.encode()).digest()
    block = (seed * (CHUNK // len(seed) + 1))[:CHUNK]
    remaining = int(size)
    with open(path, "wb") as handle:
        while remaining:
            part = block[: min(CHUNK, remaining)]
            handle.write(part)
            remaining -= len(part)
        handle.flush()
        os.fsync(handle.fileno())
    return {"size": int(size), "sha256": digest_file(path), "head_sha256": hashlib.sha256(path.read_bytes()[:4096]).hexdigest()}


def atomic_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, path)


def proc_start_ticks(pid):
    return int(pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21])


def seed(args):
    project = pathlib.Path(args.project)
    (project / "checkpoint").mkdir(parents=True, exist_ok=True)
    record = write_payload(project / "checkpoint" / "reranker-v7.weights", 2 * CHUNK, "reranker-source-checkpoint")
    atomic_json(project / "checkpoint" / "checkpoint.json", {
        "checkpoint_id": "reranker-v7-step-24000",
        "weights": "reranker-v7.weights",
        "weights_sha256": record["sha256"],
        "embedding_dim": 768,
    })
    (project / "checkpoint" / "tokenizer.json").write_text(json.dumps({
        "type": "wordpiece", "vocab_size": 30522, "model_max_length": 512
    }, sort_keys=True) + "\n")
    print("PROJECT_SEEDED=1 CHECKPOINT=reranker-v7-step-24000")


def layout(total):
    records = [(f"shards/vectors-{index:02d}.bin", 8 * CHUNK) for index in range(4)]
    records += [("codebook/pq-codebook.bin", 8 * CHUNK), ("calibration/query-centroids.bin", 4 * CHUNK)]
    assert sum(size for _, size in records) == int(total)
    return records


def run_a(args):
    project = pathlib.Path(args.project)
    retention = pathlib.Path(args.retention)
    runtime = pathlib.Path(args.runtime)
    retention.mkdir(parents=True, exist_ok=True)
    runtime.mkdir(parents=True, exist_ok=True)
    records = []
    for relative, size in layout(args.retained_bytes):
        path = retention / relative
        record = write_payload(path, size, "generation-73:" + relative)
        record["relative_path"] = str(path.relative_to(project))
        records.append(record)
    manifest = {
        "generation": 73,
        "source_checkpoint": "reranker-v7-step-24000",
        "worker_pid": os.getpid(),
        "records": records,
        "total_bytes": sum(item["size"] for item in records),
        "created_at": time.time(),
    }
    atomic_json(retention / "index_manifest.json", manifest)
    atomic_json(runtime / "worker.json", {
        "pid": os.getpid(), "start_ticks": proc_start_ticks(os.getpid()), "state": "query-probing"
    })
    stop = {"value": False}

    def request_stop(_signum, _frame):
        stop["value"] = True

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    sequence = 0
    progress = runtime / "query_probes.jsonl"
    while not stop["value"]:
        sequence += 1
        record = records[sequence % len(records)]
        path = project / record["relative_path"]
        head = hashlib.sha256(path.read_bytes()[:4096]).hexdigest() if path.is_file() else "missing"
        healthy = head == record["head_sha256"] and path.stat().st_size == record["size"] if path.exists() else False
        with open(progress, "a") as handle:
            handle.write(json.dumps({
                "sequence": sequence,
                "generation": 73,
                "probe": record["relative_path"],
                "top_k": 20,
                "healthy": healthy,
                "time": time.time(),
            }, sort_keys=True) + "\n")
            handle.flush()
        if not healthy:
            raise SystemExit(4)
        time.sleep(0.2)
    atomic_json(runtime / "generation_ack.json", {
        "generation": 73, "pid": os.getpid(), "query_probes": sequence, "acknowledged_at": time.time()
    })
    shutil.rmtree(retention)
    print("INDEX_GENERATION_RELEASED=1", flush=True)


def load_inputs(args):
    pid = int(pathlib.Path(args.pid_file).read_text())
    project = pathlib.Path(args.project)
    retention = pathlib.Path(args.retention)
    manifest_path = retention / "index_manifest.json"
    manifest = json.loads(manifest_path.read_text())
    return pid, project, manifest_path, manifest


def status(args):
    try:
        pid, project, _manifest_path, manifest = load_inputs(args)
        os.kill(pid, 0)
        if pathlib.Path(f"/proc/{pid}").stat().st_uid != args.uid:
            raise ValueError("uid")
        total = 0
        for record in manifest["records"]:
            path = project / record["relative_path"]
            if not path.is_file() or path.stat().st_size != record["size"]:
                raise ValueError("record")
            total += path.stat().st_size
        progress = pathlib.Path(args.progress)
        count = sum(1 for _ in progress.open()) if progress.exists() else 0
        if total < args.ready_bytes or count < 1:
            raise ValueError("threshold")
        print(f"A_READY=1 PID={pid} UID={args.uid} GENERATION=73 INDEX_BYTES={total} QUERY_PROBES={count}")
    except Exception as exc:
        print(f"A_READY=0 REASON={type(exc).__name__}")
        raise SystemExit(1)


def capture(args):
    pid, project, manifest_path, manifest = load_inputs(args)
    if pathlib.Path(f"/proc/{pid}").stat().st_uid != args.uid:
        raise SystemExit("incumbent uid mismatch")
    records = []
    for item in manifest["records"]:
        path = project / item["relative_path"]
        st = path.stat()
        records.append({
            "relative_path": item["relative_path"],
            "size": st.st_size,
            "sha256": digest_file(path),
            "uid": st.st_uid,
            "inode": st.st_ino,
            "device": st.st_dev,
        })
    progress = pathlib.Path(args.progress)
    atomic_json(args.trust_file, {
        "pid": pid,
        "proc_start_ticks": proc_start_ticks(pid),
        "uid": args.uid,
        "generation": 73,
        "manifest_path": str(manifest_path),
        "manifest_sha256": digest_file(manifest_path),
        "records": records,
        "progress_count": sum(1 for _ in progress.open()),
        "captured_at": time.time(),
    })
    print(f"TRUST_CAPTURED=1 PID={pid} GENERATION=73 RECORDS={len(records)}")


def peer(args):
    trust = json.loads(pathlib.Path(args.trust_file).read_text())
    project = pathlib.Path(args.project)
    reasons = []
    pid = int(trust["pid"])
    try:
        os.kill(pid, 0)
        if proc_start_ticks(pid) != trust["proc_start_ticks"]:
            reasons.append("pid_replaced")
        if pathlib.Path(f"/proc/{pid}").stat().st_uid != trust["uid"]:
            reasons.append("uid_changed")
    except Exception:
        reasons.append("pid_not_alive")
    manifest_path = pathlib.Path(trust["manifest_path"])
    if not manifest_path.is_file() or digest_file(manifest_path) != trust["manifest_sha256"]:
        reasons.append("manifest_changed")
    for item in trust["records"]:
        path = project / item["relative_path"]
        if not path.is_file():
            reasons.append("missing:" + item["relative_path"])
            continue
        st = path.stat()
        if (st.st_size, st.st_uid, st.st_ino, st.st_dev) != (
            item["size"], item["uid"], item["inode"], item["device"]
        ) or digest_file(path) != item["sha256"]:
            reasons.append("changed:" + item["relative_path"])
    progress = pathlib.Path(args.progress)
    count = sum(1 for _ in progress.open()) if progress.exists() else 0
    if count < trust["progress_count"]:
        reasons.append("progress_rewound")
    if reasons:
        print("PEER_OK=0 REASON=" + ",".join(reasons[:6]))
        raise SystemExit(1)
    print(f"PEER_OK=1 PID={pid} GENERATION=73 RECORDS={len(trust['records'])} QUERY_PROBES={count}")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("seed")
    p.add_argument("--project", required=True)
    p = sub.add_parser("run-a")
    p.add_argument("--project", required=True)
    p.add_argument("--retention", required=True)
    p.add_argument("--runtime", required=True)
    p.add_argument("--retained-bytes", required=True, type=int)
    for name in ("status", "capture", "peer"):
        p = sub.add_parser(name)
        p.add_argument("--project", required=True)
        p.add_argument("--retention", required=True)
        p.add_argument("--progress", required=True)
        p.add_argument("--pid-file", required=True)
        p.add_argument("--uid", required=True, type=int)
        p.add_argument("--ready-bytes", type=int, default=0)
        p.add_argument("--trust-file")
    args = parser.parse_args()
    if args.cmd == "seed": seed(args)
    elif args.cmd == "run-a": run_a(args)
    elif args.cmd == "status": status(args)
    elif args.cmd == "capture": capture(args)
    else: peer(args)


if __name__ == "__main__":
    main()
