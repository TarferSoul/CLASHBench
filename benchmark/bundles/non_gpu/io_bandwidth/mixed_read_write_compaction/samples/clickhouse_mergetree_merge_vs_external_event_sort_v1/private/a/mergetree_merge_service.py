#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import time


CHUNK = 1024 * 1024


def fsync_dir(path):
    fd = os.open(str(path), os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    with tmp.open("rb") as handle:
        os.fsync(handle.fileno())
    tmp.replace(path)
    fsync_dir(path.parent)


def append_jsonl(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n")
        handle.flush()
        os.fsync(handle.fileno())


def read_json(path, default=None):
    try:
        return json.loads(pathlib.Path(path).read_text())
    except Exception:
        return default


def proc_start_time(pid):
    try:
        stat = pathlib.Path(f"/proc/{pid}/stat").read_text()
        return stat.rsplit(") ", 1)[1].split()[19]
    except Exception:
        return ""


def alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except OSError:
        return False


def drop_cache(path):
    try:
        fd = os.open(str(path), os.O_RDONLY)
    except OSError:
        return
    try:
        if hasattr(os, "posix_fadvise"):
            os.posix_fadvise(fd, 0, 0, getattr(os, "POSIX_FADV_DONTNEED", 4))
    except OSError:
        pass
    finally:
        os.close(fd)


def pattern_chunk(part_index, offset, size):
    seed = hashlib.blake2b(f"part={part_index};offset={offset}".encode(), digest_size=32).digest()
    repeat = (seed * ((size // len(seed)) + 1))[:size]
    return repeat


def write_part_file(path, part_index, size):
    digest = hashlib.sha256()
    with pathlib.Path(path).open("wb") as handle:
        remaining = size
        offset = 0
        while remaining > 0:
            take = min(CHUNK, remaining)
            chunk = pattern_chunk(part_index, offset, take)
            handle.write(chunk)
            digest.update(chunk)
            remaining -= take
            offset += take
        handle.flush()
        os.fsync(handle.fileno())
    drop_cache(path)
    return digest.hexdigest()


def seed_parts(data_dir, source_parts, part_bytes):
    data_dir = pathlib.Path(data_dir)
    source = data_dir / "source_parts"
    manifest = data_dir / "metadata" / "source_manifest.json"
    existing = read_json(manifest, {})
    if (
        existing
        and existing.get("source_parts") == source_parts
        and existing.get("part_bytes") == part_bytes
        and all((source / item["file"]).exists() for item in existing.get("parts", []))
    ):
        return existing
    shutil.rmtree(source, ignore_errors=True)
    shutil.rmtree(data_dir / "merged_parts", ignore_errors=True)
    (data_dir / "metadata").mkdir(parents=True, exist_ok=True)
    source.mkdir(parents=True, exist_ok=True)
    parts = []
    for index in range(source_parts):
        part_dir = source / f"part_{index:03d}"
        part_dir.mkdir(parents=True, exist_ok=True)
        data_path = part_dir / "events.bin"
        digest = write_part_file(data_path, index, part_bytes)
        checksums = {
            "part": part_dir.name,
            "events.bin": {"bytes": part_bytes, "sha256": digest},
            "marks": {"rows": part_bytes // 256, "min_ts": 1730500000 + index * 1000, "max_ts": 1730500999 + index * 1000},
        }
        atomic_json(part_dir / "checksums.json", checksums)
        atomic_json(part_dir / "primary.idx", {"part": part_dir.name, "mark_count": max(1, part_bytes // (256 * 8192))})
        parts.append({"file": str(data_path.relative_to(source)), "part": part_dir.name, "bytes": part_bytes, "sha256": digest})
    value = {
        "format": "local-mergetree-parts-v1",
        "source_parts": source_parts,
        "part_bytes": part_bytes,
        "created_at": time.time(),
        "parts": parts,
    }
    atomic_json(manifest, value)
    atomic_json(data_dir / "metadata" / "query_probe.json", {"row_estimate": source_parts * (part_bytes // 256), "part_count": source_parts})
    fsync_dir(data_dir / "metadata")
    return value


def query_probe(data_dir):
    data_dir = pathlib.Path(data_dir)
    manifest = read_json(data_dir / "metadata" / "source_manifest.json", {})
    probe = read_json(data_dir / "metadata" / "query_probe.json", {})
    if not manifest or not probe:
        return False
    if int(probe.get("part_count", -1)) != int(manifest.get("source_parts", -2)):
        return False
    for item in manifest.get("parts", [])[:3]:
        if not (data_dir / "source_parts" / item["file"]).exists():
            return False
    return True


def worker_status_path(state_dir, worker_id):
    return pathlib.Path(state_dir) / "workers" / f"worker_{worker_id:02d}.json"


def read_worker_statuses(state_dir):
    statuses = []
    for path in sorted((pathlib.Path(state_dir) / "workers").glob("worker_*.json")):
        status = read_json(path, {})
        if status:
            statuses.append(status)
    return statuses


def merge_once(args, worker_id, seq, source_items, base_read, base_write):
    data_dir = pathlib.Path(args.data_dir)
    state_dir = pathlib.Path(args.state_dir)
    source_root = data_dir / "source_parts"
    merging = data_dir / "merging"
    merged = data_dir / "merged_parts"
    merging.mkdir(parents=True, exist_ok=True)
    merged.mkdir(parents=True, exist_ok=True)
    left = source_items[(worker_id + seq) % len(source_items)]
    right = source_items[(worker_id * 3 + seq + 1) % len(source_items)]
    merge_id = f"merge-w{worker_id:02d}-{seq:04d}"
    tmp_dir = merging / f"{merge_id}.tmp"
    final_dir = merged / merge_id
    shutil.rmtree(tmp_dir, ignore_errors=True)
    tmp_dir.mkdir(parents=True, exist_ok=True)
    out_path = tmp_dir / "events.bin"
    read_bytes = 0
    write_bytes = 0
    digest = hashlib.sha256()
    sources = [source_root / left["file"], source_root / right["file"]]
    for src in sources:
        drop_cache(src)
    with out_path.open("wb") as out:
        for source_index, src in enumerate(sources):
            with src.open("rb") as handle:
                chunk_index = 0
                while True:
                    chunk = handle.read(CHUNK)
                    if not chunk:
                        break
                    read_bytes += len(chunk)
                    if chunk_index % 2 == source_index % 2:
                        out.write(chunk)
                        digest.update(chunk)
                        write_bytes += len(chunk)
                    chunk_index += 1
                    if chunk_index % 4 == 0:
                        atomic_json(
                            worker_status_path(state_dir, worker_id),
                            {
                                "pid": os.getpid(),
                                "start_time": proc_start_time(os.getpid()),
                                "worker_id": worker_id,
                                "phase": "merging",
                                "merge_id": merge_id,
                                "seq": seq,
                                "read_bytes": base_read + read_bytes,
                                "write_bytes": base_write + write_bytes,
                                "completed_merges": seq,
                                "updated_at": time.time(),
                            },
                        )
                drop_cache(src)
        out.flush()
        os.fsync(out.fileno())
    atomic_json(tmp_dir / "checksums.json", {"merge_id": merge_id, "sources": [left["part"], right["part"]], "events.bin": {"bytes": write_bytes, "sha256": digest.hexdigest()}})
    atomic_json(tmp_dir / "primary.idx", {"merge_id": merge_id, "mark_count": max(1, write_bytes // (256 * 8192))})
    tmp_dir.replace(final_dir)
    fsync_dir(merged)
    append_jsonl(
        data_dir / "metadata" / "merge_log.jsonl",
        {
            "merge_id": merge_id,
            "worker_id": worker_id,
            "read_bytes": read_bytes,
            "write_bytes": write_bytes,
            "sources": [left["part"], right["part"]],
            "published_part": final_dir.name,
            "published_at": time.time(),
        },
    )
    drop_cache(final_dir / "events.bin")
    return read_bytes, write_bytes, merge_id


def run_worker(args):
    pathlib.Path(args.state_dir, "workers").mkdir(parents=True, exist_ok=True)
    manifest = read_json(pathlib.Path(args.data_dir) / "metadata" / "source_manifest.json", {})
    source_items = manifest.get("parts", [])
    total_read = 0
    total_write = 0
    worker_id = args.worker_id
    start = time.time()
    seq = 0
    while seq < args.rounds and time.time() < args.end_at:
        if pathlib.Path(args.state_dir, "stop.requested").exists() or pathlib.Path(args.state_dir, "drain.requested").exists():
            break
        read_bytes, write_bytes, merge_id = merge_once(args, worker_id, seq, source_items, total_read, total_write)
        total_read += read_bytes
        total_write += write_bytes
        seq += 1
        atomic_json(
            worker_status_path(args.state_dir, worker_id),
            {
                "pid": os.getpid(),
                "start_time": proc_start_time(os.getpid()),
                "worker_id": worker_id,
                "phase": "active" if seq < args.rounds else "complete",
                "merge_id": merge_id,
                "seq": seq,
                "read_bytes": total_read,
                "write_bytes": total_write,
                "completed_merges": seq,
                "updated_at": time.time(),
                "elapsed": time.time() - start,
            },
        )
    atomic_json(
        worker_status_path(args.state_dir, worker_id),
        {
            "pid": os.getpid(),
            "start_time": proc_start_time(os.getpid()),
            "worker_id": worker_id,
            "phase": "complete",
            "seq": seq,
            "read_bytes": total_read,
            "write_bytes": total_write,
            "completed_merges": seq,
            "updated_at": time.time(),
            "elapsed": time.time() - start,
        },
    )
    return 0


def aggregate_status(data_dir, state_dir, supervisor_pid, supervisor_start, workers, phase, exit_reason=""):
    statuses = read_worker_statuses(state_dir)
    active_worker_pids = []
    worker_rows = []
    for status in statuses:
        pid = int(status.get("pid") or 0)
        is_alive = bool(pid and alive(pid) and proc_start_time(pid) == str(status.get("start_time", "")))
        if is_alive and status.get("phase") != "complete":
            active_worker_pids.append(pid)
        worker_rows.append({**status, "alive": is_alive})
    total_read = sum(int(row.get("read_bytes") or 0) for row in worker_rows)
    total_write = sum(int(row.get("write_bytes") or 0) for row in worker_rows)
    completed = sum(int(row.get("completed_merges") or 0) for row in worker_rows)
    status = {
        "service": "local-mergetree-merge-maintenance",
        "pid": supervisor_pid,
        "start_time": supervisor_start,
        "pgid": os.getpgid(supervisor_pid),
        "phase": phase,
        "exit_reason": exit_reason,
        "active_workers": len(active_worker_pids),
        "worker_pids": active_worker_pids,
        "workers": worker_rows,
        "merge_task_count": completed,
        "bytes_read_uncompressed": total_read,
        "bytes_written_uncompressed": total_write,
        "query_probe_ok": query_probe(data_dir),
        "updated_at": time.time(),
    }
    atomic_json(pathlib.Path(state_dir) / "status.json", status)
    return status


def run_supervisor(args):
    data_dir = pathlib.Path(args.data_dir)
    state_dir = pathlib.Path(args.state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    (state_dir / "workers").mkdir(parents=True, exist_ok=True)
    for marker in ("stop.requested", "drain.requested", "final_status.json"):
        path = state_dir / marker
        if path.exists():
            path.unlink()
    for old in (state_dir / "workers").glob("worker_*.json"):
        old.unlink()
    seed_parts(data_dir, args.source_parts, args.part_bytes)
    pid = os.getpid()
    start_time = proc_start_time(pid)
    (state_dir / "supervisor.pid").write_text(f"{pid}\n")
    (state_dir / "supervisor.start").write_text(f"{start_time}\n")
    end_at = time.time() + args.runtime_seconds
    workers = []
    for worker_id in range(args.workers):
        command = [
            sys.executable,
            __file__,
            "worker",
            "--data-dir",
            str(data_dir),
            "--state-dir",
            str(state_dir),
            "--worker-id",
            str(worker_id),
            "--rounds",
            str(args.rounds),
            "--end-at",
            str(end_at),
        ]
        workers.append(subprocess.Popen(command))
    phase = "active"
    def mark_stop(_signum, _frame):
        (state_dir / "stop.requested").write_text(f"{time.time()}\n")
    signal.signal(signal.SIGTERM, mark_stop)
    signal.signal(signal.SIGINT, mark_stop)
    while True:
        stopped = (state_dir / "stop.requested").exists()
        still_running = [proc for proc in workers if proc.poll() is None]
        if stopped:
            phase = "stopping"
            break
        if not still_running:
            phase = "complete"
            break
        if time.time() >= end_at:
            phase = "draining"
            (state_dir / "drain.requested").write_text(f"{time.time()}\n")
        aggregate_status(data_dir, state_dir, pid, start_time, workers, phase)
        if phase == "draining":
            break
        time.sleep(0.25)
    deadline = time.time() + 20
    while time.time() < deadline:
        still_running = [proc for proc in workers if proc.poll() is None]
        if not still_running:
            break
        if phase == "stopping":
            for proc in still_running:
                proc.terminate()
        time.sleep(0.2)
    for proc in workers:
        if proc.poll() is None:
            proc.kill()
    for proc in workers:
        proc.wait(timeout=5)
    exit_reason = "stop_requested" if phase == "stopping" else "finished_merge_window"
    final = aggregate_status(data_dir, state_dir, pid, start_time, workers, "complete", exit_reason=exit_reason)
    final["completed_at"] = time.time()
    atomic_json(state_dir / "final_status.json", final)
    return 0 if exit_reason == "finished_merge_window" else 0


def command_status(args):
    status_path = pathlib.Path(args.state_dir) / "status.json"
    status = read_json(status_path, {})
    pid_file = pathlib.Path(args.state_dir) / "supervisor.pid"
    pid = int(pid_file.read_text().strip()) if pid_file.exists() and pid_file.read_text().strip().isdigit() else 0
    live = bool(pid and alive(pid))
    if live:
        status = aggregate_status(args.data_dir, args.state_dir, pid, proc_start_time(pid), [], status.get("phase", "active"))
    final = read_json(pathlib.Path(args.state_dir) / "final_status.json", {})
    probe = query_probe(args.data_dir)
    healthy = False
    reason = "unknown"
    if args.require_ready:
        healthy = (
            live
            and status.get("phase") in {"active", "draining"}
            and int(status.get("active_workers") or 0) >= args.min_workers
            and int(status.get("bytes_read_uncompressed") or 0) >= args.min_read_bytes
            and int(status.get("bytes_written_uncompressed") or 0) >= args.min_write_bytes
            and probe
        )
        reason = "ready" if healthy else "not_ready"
    elif args.require_complete:
        healthy = bool(final and final.get("exit_reason") == "finished_merge_window" and probe)
        reason = "complete" if healthy else "not_complete"
        status = final or status
    else:
        healthy = bool((live or (final and final.get("exit_reason") == "finished_merge_window")) and probe)
        reason = "healthy" if healthy else "unhealthy"
        if not live and final:
            status = final
    line = (
        f"A_STATUS_OK={1 if healthy else 0} reason={reason} pid={pid} "
        f"phase={status.get('phase', '')} active_workers={status.get('active_workers', 0)} "
        f"merge_task_count={status.get('merge_task_count', 0)} "
        f"bytes_read_uncompressed={status.get('bytes_read_uncompressed', 0)} "
        f"bytes_written_uncompressed={status.get('bytes_written_uncompressed', 0)} "
        f"query_probe_ok={1 if probe else 0}"
    )
    print(line)
    if args.json_out:
        pathlib.Path(args.json_out).write_text(json.dumps(status, sort_keys=True, indent=2) + "\n")
    return 0 if healthy else 1


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    sup = sub.add_parser("supervise")
    sup.add_argument("--data-dir", required=True)
    sup.add_argument("--state-dir", required=True)
    sup.add_argument("--source-parts", type=int, required=True)
    sup.add_argument("--part-bytes", type=int, required=True)
    sup.add_argument("--workers", type=int, required=True)
    sup.add_argument("--runtime-seconds", type=float, required=True)
    sup.add_argument("--rounds", type=int, required=True)
    worker = sub.add_parser("worker")
    worker.add_argument("--data-dir", required=True)
    worker.add_argument("--state-dir", required=True)
    worker.add_argument("--worker-id", type=int, required=True)
    worker.add_argument("--rounds", type=int, required=True)
    worker.add_argument("--end-at", type=float, required=True)
    status = sub.add_parser("status")
    status.add_argument("--data-dir", required=True)
    status.add_argument("--state-dir", required=True)
    status.add_argument("--require-ready", action="store_true")
    status.add_argument("--require-complete", action="store_true")
    status.add_argument("--min-workers", type=int, default=2)
    status.add_argument("--min-read-bytes", type=int, default=1)
    status.add_argument("--min-write-bytes", type=int, default=1)
    status.add_argument("--json-out", default="")
    args = parser.parse_args()
    if args.cmd == "supervise":
        return run_supervisor(args)
    if args.cmd == "worker":
        return run_worker(args)
    if args.cmd == "status":
        return command_status(args)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
