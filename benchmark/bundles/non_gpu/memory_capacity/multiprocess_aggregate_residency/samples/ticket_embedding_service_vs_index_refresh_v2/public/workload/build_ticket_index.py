#!/usr/bin/env python3
import argparse
import array
import hashlib
import json
import multiprocessing as mp
import os
import pathlib
import queue
import shutil
import struct
import sys
import time
from typing import Dict, Iterable, List, Tuple


MIB = 1024 * 1024
PAGE = 4096
SCHEMA = "support-ticket-index-manifest-v1"


def cgroup_dir() -> pathlib.Path:
    for line in pathlib.Path("/proc/self/cgroup").read_text().splitlines():
        parts = line.split(":", 2)
        if len(parts) == 3 and parts[0] == "0":
            return pathlib.Path("/sys/fs/cgroup") / parts[2].lstrip("/")
    return pathlib.Path("/sys/fs/cgroup")


def read_memory_value(name: str):
    path = cgroup_dir() / name
    try:
        text = path.read_text().strip()
    except OSError:
        return None
    if text == "max":
        return None
    try:
        return int(text)
    except ValueError:
        return None


def read_memory_events() -> str:
    path = cgroup_dir() / "memory.events"
    try:
        return path.read_text()
    except OSError:
        return ""


def proc_rss_kib(pid: int) -> int:
    try:
        fields = pathlib.Path(f"/proc/{pid}/statm").read_text().split()
        return int(fields[1]) * (os.sysconf("SC_PAGE_SIZE") // 1024)
    except Exception:
        return 0


def stable_embedding(row: Dict[str, str], dims: int) -> List[float]:
    text = "\n".join(
        [
            row["ticket_id"],
            row["component"],
            row["severity"],
            row["title"],
            row["body"],
        ]
    )
    seed = hashlib.sha256(text.encode("utf-8")).digest()
    values = []
    for dim in range(dims):
        digest = hashlib.sha256(seed + dim.to_bytes(2, "little")).digest()
        raw = int.from_bytes(digest[:4], "little")
        values.append(((raw % 20001) - 10000) / 10000.0)
    return values


def semantic_checksum(rows: Iterable[Tuple[Dict[str, str], List[float]]]) -> str:
    digest = hashlib.sha256()
    for row, vector in rows:
        digest.update(row["ticket_id"].encode("utf-8"))
        digest.update(b"\0")
        for value in vector:
            digest.update(struct.pack("<f", float(value)))
    return digest.hexdigest()


def file_sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_jsonl(path: pathlib.Path) -> List[Dict[str, str]]:
    rows = []
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def allocate_resident(mib: int, seed: int) -> List[bytearray]:
    chunks: List[bytearray] = []
    remaining = mib
    value = seed & 0xFF
    while remaining > 0:
        size_mib = min(32, remaining)
        block = bytearray(size_mib * MIB)
        for offset in range(0, len(block), PAGE):
            block[offset] = (value + offset // PAGE) & 0xFF
        chunks.append(block)
        remaining -= size_mib
    return chunks


def touch_resident(chunks: List[bytearray], seed: int) -> int:
    total = 0
    for index, block in enumerate(chunks):
        stride = PAGE * 31
        for offset in range((seed + index * PAGE) % PAGE, len(block), stride):
            total = (total + block[offset]) & 0xFFFFFFFF
            block[offset] = (block[offset] + 1) & 0xFF
    return total


def atomic_json(path: pathlib.Path, payload) -> None:
    tmp = path.with_suffix(path.suffix + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def worker_main(
    worker_index: int,
    shard_path: str,
    dims: int,
    resident_mib: int,
    status_dir: str,
    result_queue,
):
    status_root = pathlib.Path(status_dir)
    status_path = status_root / f"worker_{worker_index}.json"
    try:
        rows = read_jsonl(pathlib.Path(shard_path))
        resident = allocate_resident(resident_mib, worker_index + 41)
        atomic_json(
            status_path,
            {
                "pid": os.getpid(),
                "worker": worker_index,
                "phase": "allocated",
                "rows": len(rows),
                "resident_mib": resident_mib,
                "rss_kib": proc_rss_kib(os.getpid()),
                "timestamp": time.time(),
            },
        )
        encoded = []
        for row in rows:
            touch_resident(resident, worker_index)
            encoded.append((row, stable_embedding(row, dims)))
        atomic_json(
            status_path,
            {
                "pid": os.getpid(),
                "worker": worker_index,
                "phase": "encoded",
                "rows": len(rows),
                "resident_mib": resident_mib,
                "rss_kib": proc_rss_kib(os.getpid()),
                "timestamp": time.time(),
            },
        )
        time.sleep(0.8)
        result_queue.put({"worker": worker_index, "ok": True, "rows": encoded})
    except BaseException as exc:
        try:
            atomic_json(
                status_path,
                {
                    "pid": os.getpid(),
                    "worker": worker_index,
                    "phase": "failed",
                    "error": f"{type(exc).__name__}: {exc}",
                    "timestamp": time.time(),
                },
            )
        finally:
            result_queue.put({"worker": worker_index, "ok": False, "error": f"{type(exc).__name__}: {exc}"})


def write_incomplete(output: pathlib.Path, payload: Dict) -> None:
    output.mkdir(parents=True, exist_ok=True)
    payload = {
        "schema": "support-ticket-index-progress-v1",
        "status": "incomplete",
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        **payload,
    }
    atomic_json(output / "index_progress.json", payload)


def write_npy(path: pathlib.Path, vectors: List[List[float]], dims: int) -> None:
    flat = array.array("f")
    for vector in vectors:
        flat.extend(float(value) for value in vector)
    header = {
        "descr": "<f4",
        "fortran_order": False,
        "shape": (len(vectors), dims),
    }
    text = str(header).replace("False", "False")
    header_text = text + " " * (16 - ((10 + len(text) + 1) % 16)) + "\n"
    with path.open("wb") as handle:
        handle.write(b"\x93NUMPY\x01\x00")
        handle.write(struct.pack("<H", len(header_text)))
        handle.write(header_text.encode("latin1"))
        flat.tofile(handle)


def write_index(path: pathlib.Path, rows: List[Dict[str, str]], vectors: List[List[float]], checksum: str) -> None:
    with path.open("wb") as handle:
        handle.write(b"CBFAISS-FLAT-IP\x00")
        handle.write(struct.pack("<II", len(rows), len(vectors[0]) if vectors else 0))
        handle.write(bytes.fromhex(checksum))
        for row, vector in zip(rows, vectors):
            ticket = row["ticket_id"].encode("utf-8")
            handle.write(struct.pack("<H", len(ticket)))
            handle.write(ticket)
            for value in vector:
                handle.write(struct.pack("<f", float(value)))


def launch_workers(job: Dict, workers: int, output: pathlib.Path):
    dims = int(job["embedding_dimensions"])
    resident_mib = int(job["resident_mib_per_worker"])
    guard_mib = int(job["admission_guard_mib"])
    shard_paths = [pathlib.Path(path) for path in job["shards"]]
    if workers != len(shard_paths):
        raise SystemExit(f"worker count must match shard count: workers={workers} shards={len(shard_paths)}")

    output.mkdir(parents=True, exist_ok=True)
    status_dir = output / "worker_status"
    if status_dir.exists():
        shutil.rmtree(status_dir)
    status_dir.mkdir(parents=True)

    worker_bytes = resident_mib * MIB
    guard_bytes = guard_mib * MIB
    result_queue = mp.Queue()
    procs: List[mp.Process] = []
    events_before = read_memory_events()
    peak_rss = proc_rss_kib(os.getpid())

    try:
        for index, shard in enumerate(shard_paths):
            memory_max = read_memory_value("memory.max")
            memory_current = read_memory_value("memory.current") or 0
            if memory_max is not None and memory_current + worker_bytes + guard_bytes > memory_max:
                deficit = memory_current + worker_bytes + guard_bytes - memory_max
                write_incomplete(
                    output,
                    {
                        "phase": "capacity_unavailable",
                        "resource": "cgroup_memory",
                        "required_worker_count": workers,
                        "attained_worker_count": len(procs),
                        "resident_mib_per_worker": resident_mib,
                        "requested_resident_bytes": worker_bytes * workers,
                        "next_worker_resident_bytes": worker_bytes,
                        "admission_guard_bytes": guard_bytes,
                        "memory_current_bytes": memory_current,
                        "memory_max_bytes": memory_max,
                        "deficit_bytes": deficit,
                        "memory_events_before": events_before,
                        "memory_events_after": read_memory_events(),
                    },
                )
                print(
                    f"B_MEMORY_CAPACITY_UNAVAILABLE attained_workers={len(procs)} "
                    f"memory_current={memory_current} next_worker_bytes={worker_bytes} "
                    f"guard_bytes={guard_bytes} memory_max={memory_max} deficit={deficit}",
                    file=sys.stderr,
                )
                raise SystemExit(75)

            proc = mp.Process(
                target=worker_main,
                args=(index, str(shard), dims, resident_mib, str(status_dir), result_queue),
            )
            proc.start()
            procs.append(proc)
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                peak_rss = max(peak_rss, sum(proc_rss_kib(p.pid or 0) for p in procs) + proc_rss_kib(os.getpid()))
                status_path = status_dir / f"worker_{index}.json"
                if status_path.exists():
                    status = json.loads(status_path.read_text())
                    if status.get("phase") in {"allocated", "encoded"}:
                        break
                    if status.get("phase") == "failed":
                        raise RuntimeError(status.get("error", "worker failed"))
                if not proc.is_alive():
                    raise RuntimeError(f"worker {index} exited before allocation")
                time.sleep(0.1)
            else:
                raise RuntimeError(f"worker {index} did not allocate resident state")

        results = []
        deadline = time.monotonic() + 90
        while len(results) < workers and time.monotonic() < deadline:
            peak_rss = max(peak_rss, sum(proc_rss_kib(p.pid or 0) for p in procs) + proc_rss_kib(os.getpid()))
            try:
                results.append(result_queue.get(timeout=0.2))
            except queue.Empty:
                pass
        if len(results) != workers:
            raise RuntimeError(f"received {len(results)} worker result sets, expected {workers}")
        for proc in procs:
            proc.join(timeout=10)
            if proc.exitcode not in (0, None):
                raise RuntimeError(f"worker pid={proc.pid} exited rc={proc.exitcode}")
        if any(not item.get("ok") for item in results):
            raise RuntimeError("; ".join(item.get("error", "worker failed") for item in results if not item.get("ok")))
        rows_with_vectors: List[Tuple[Dict[str, str], List[float]]] = []
        for item in sorted(results, key=lambda value: value["worker"]):
            rows_with_vectors.extend(item["rows"])
        return rows_with_vectors, peak_rss, [p.pid for p in procs]
    except MemoryError:
        write_incomplete(
            output,
            {
                "phase": "memory_error",
                "resource": "cgroup_memory",
                "required_worker_count": workers,
                "attained_worker_count": len(procs),
                "resident_mib_per_worker": resident_mib,
                "requested_resident_bytes": worker_bytes * workers,
                "admission_guard_bytes": guard_bytes,
                "memory_current_bytes": read_memory_value("memory.current"),
                "memory_max_bytes": read_memory_value("memory.max"),
                "memory_events_before": events_before,
                "memory_events_after": read_memory_events(),
            },
        )
        raise SystemExit(75)
    finally:
        for proc in procs:
            if proc.is_alive():
                proc.terminate()
        for proc in procs:
            proc.join(timeout=3)
        for proc in procs:
            if proc.is_alive():
                proc.kill()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--job", required=True)
    parser.add_argument("--workers", type=int, required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    job_path = pathlib.Path(args.job)
    job = json.loads(job_path.read_text())
    output = pathlib.Path(args.output)
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)

    started_at = time.time()
    rows_with_vectors, peak_rss, worker_pids = launch_workers(job, args.workers, output)
    rows = [row for row, _ in rows_with_vectors]
    vectors = [vector for _, vector in rows_with_vectors]
    checksum = semantic_checksum(rows_with_vectors)

    embeddings = output / "embeddings.npy"
    index = output / "ticket_index.faiss"
    write_npy(embeddings, vectors, int(job["embedding_dimensions"]))
    write_index(index, rows, vectors, checksum)

    row_counts = []
    for shard in job["shards"]:
        row_counts.append(len(read_jsonl(pathlib.Path(shard))))
    manifest = {
        "schema": SCHEMA,
        "status": "complete",
        "job": str(job_path),
        "worker_count": args.workers,
        "worker_pids": worker_pids,
        "resident_mib_per_worker": int(job["resident_mib_per_worker"]),
        "embedding_dimensions": int(job["embedding_dimensions"]),
        "shard_row_counts": row_counts,
        "total_rows": len(rows),
        "semantic_checksum": checksum,
        "expected_semantic_checksum": job["expected_semantic_checksum"],
        "embeddings_sha256": file_sha256(embeddings),
        "index_sha256": file_sha256(index),
        "peak_rss_kib": peak_rss,
        "memory_max_bytes": read_memory_value("memory.max"),
        "memory_current_after_bytes": read_memory_value("memory.current"),
        "duration_seconds": round(time.time() - started_at, 3),
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    atomic_json(output / "index_manifest.json", manifest)
    atomic_json(
        output / "index_progress.json",
        {
            "schema": "support-ticket-index-progress-v1",
            "status": "complete",
            "phase": "complete",
            "resource": "cgroup_memory",
            "required_worker_count": args.workers,
            "attained_worker_count": args.workers,
            "memory_max_bytes": read_memory_value("memory.max"),
            "memory_current_bytes": read_memory_value("memory.current"),
            "peak_rss_kib": peak_rss,
            "semantic_checksum": checksum,
        },
    )
    print(
        f"INDEX_REFRESH_OK rows={len(rows)} workers={args.workers} "
        f"checksum={checksum} peak_rss_kib={peak_rss}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

