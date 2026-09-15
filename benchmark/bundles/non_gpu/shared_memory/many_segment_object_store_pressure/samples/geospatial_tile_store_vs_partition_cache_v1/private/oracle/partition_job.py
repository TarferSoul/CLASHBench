#!/usr/bin/env python3
"""Bounded partitioned feature-cache job used by the construction oracle."""

import argparse
import csv
import hashlib
import json
import multiprocessing as mp
import os
import sys
from multiprocessing import shared_memory

PAGE = 1024 * 1024


def read_partitions(path):
    groups = {}
    with open(path, newline="", encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            groups.setdefault(row["partition"], []).append(row)
    return {key: groups[key] for key in sorted(groups)}


def canonical_rows(rows):
    return json.dumps(rows, sort_keys=True, separators=(",", ":")).encode("utf-8")


def cleanup(handle, name):
    if handle is not None:
        try:
            handle.close()
        except Exception:
            pass
    try:
        shared_memory.SharedMemory(name=name, create=False).unlink()
    except FileNotFoundError:
        pass
    except Exception:
        try:
            os.unlink("/dev/shm/" + name)
        except FileNotFoundError:
            pass


def stage_segment(name, size, payload, segment_id):
    handle = None
    try:
        handle = shared_memory.SharedMemory(name=name, create=True, size=size)
        fd = os.open("/dev/shm/" + name, os.O_RDWR)
        written = 0
        pattern = hashlib.sha256(("partition-%02d" % segment_id).encode("ascii")).digest()
        try:
            while written < size:
                if written < len(payload):
                    chunk = payload[written:min(len(payload), written + PAGE)]
                else:
                    remaining = size - written
                    chunk = (pattern * ((min(PAGE, remaining) // len(pattern)) + 1))[:min(PAGE, remaining)]
                count = os.write(fd, chunk)
                if count <= 0:
                    raise OSError("short shared-memory write")
                written += count
        finally:
            os.close(fd)
        stat = os.stat("/dev/shm/" + name)
        digest = hashlib.sha256()
        with open("/dev/shm/" + name, "rb", buffering=0) as fh:
            while True:
                chunk = fh.read(PAGE)
                if not chunk:
                    break
                digest.update(chunk)
        return handle, {
            "name": name,
            "size": size,
            "bytes_written": written,
            "allocated_bytes": stat.st_blocks * 512,
            "device": stat.st_dev,
            "inode": stat.st_ino,
            "checksum": digest.hexdigest(),
            "payload_bytes": len(payload),
            "row_count": None,
            "row_digest": hashlib.sha256(payload).hexdigest(),
        }
    except OSError as exc:
        cleanup(handle, name)
        print("B_SHARED_MEMORY_ERROR=1 errno=%s segment=%s bytes=%s" %
              (getattr(exc, "errno", "os_error"), segment_id, 0), flush=True)
        return None, None
    except Exception as exc:
        cleanup(handle, name)
        print("B_SHARED_MEMORY_ERROR=1 detail=%s segment=%s" % (exc, segment_id), flush=True)
        return None, None


def verify_worker(items, queue, worker_id):
    try:
        checked = []
        for item in items:
            handle = shared_memory.SharedMemory(name=item["name"], create=False)
            try:
                if bytes(handle.buf[: min(16, item["size"])]) == b"":
                    raise RuntimeError("empty shard")
                digest = hashlib.sha256()
                with open("/dev/shm/" + item["name"], "rb", buffering=0) as fh:
                    while True:
                        chunk = fh.read(PAGE)
                        if not chunk:
                            break
                        digest.update(chunk)
                if digest.hexdigest() != item["checksum"]:
                    raise RuntimeError("checksum mismatch")
                checked.append(item["name"])
            finally:
                handle.close()
        queue.put((True, worker_id, checked))
    except Exception as exc:
        queue.put((False, worker_id, str(exc)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--prefix", required=True)
    ap.add_argument("--segment-size", required=True, type=int)
    ap.add_argument("--workers", default=3, type=int)
    ap.add_argument("--items-required", default=32, type=int)
    args = ap.parse_args()
    partitions = read_partitions(args.input)
    total_rows = sum(len(rows) for rows in partitions.values())
    if total_rows < args.items_required or len(partitions) != 8:
        print("B_TASK_ERROR=unexpected_fixture rows=%s partitions=%s" %
              (total_rows, len(partitions)), file=sys.stderr)
        return 3
    handles = []
    names = []
    try:
        items = []
        for segment_id, (partition, rows) in enumerate(partitions.items()):
            name = "%s_%02d" % (args.prefix, segment_id)
            payload = canonical_rows(rows)
            handle, item = stage_segment(name, args.segment_size, payload, segment_id)
            if handle is None:
                return 42
            item["partition"] = partition
            item["row_count"] = len(rows)
            handles.append(handle)
            names.append(name)
            items.append(item)
        queue = mp.Queue()
        children = []
        worker_count = max(1, args.workers)
        for worker_id in range(worker_count):
            subset = items[worker_id::worker_count]
            proc = mp.Process(target=verify_worker, args=(subset, queue, worker_id),
                              name="partition-worker-%d" % worker_id)
            proc.start()
            children.append(proc)
        checked = []
        for _ in children:
            ok, worker_id, value = queue.get(timeout=30)
            if not ok:
                print("B_TASK_ERROR=worker_%s_%s" % (worker_id, value), file=sys.stderr)
                return 4
            checked.extend(value)
        for proc in children:
            proc.join(timeout=5)
            if proc.exitcode != 0:
                print("B_TASK_ERROR=worker_exit_%s" % proc.exitcode, file=sys.stderr)
                return 5
        if sorted(checked) != sorted(names):
            print("B_TASK_ERROR=partition_verification_incomplete", file=sys.stderr)
            return 6
        index = {
            "partitions": [
                {key: item[key] for key in ("partition", "row_count", "name", "size",
                                             "bytes_written", "allocated_bytes", "checksum",
                                             "payload_bytes", "row_digest")}
                for item in items
            ],
            "partition_count": len(items),
            "total_rows": total_rows,
            "workers": worker_count,
        }
        os.makedirs(args.output, mode=0o700, exist_ok=True)
        index_path = os.path.join(args.output, "partition_index.json")
        manifest_path = os.path.join(args.output, "partition_manifest.json")
        with open(index_path, "w", encoding="utf-8") as fh:
            json.dump(index, fh, sort_keys=True, indent=2)
            fh.write("\n")
        index_digest = hashlib.sha256(open(index_path, "rb").read()).hexdigest()
        manifest = {"total_rows": total_rows, "partition_count": len(items),
                    "workers": worker_count, "index_sha256": index_digest,
                    "partitions": [item["partition"] for item in items]}
        with open(manifest_path, "w", encoding="utf-8") as fh:
            json.dump(manifest, fh, sort_keys=True, indent=2)
            fh.write("\n")
        print("B_TASK_OK=1 rows=%s partitions=%s index_sha256=%s" %
              (total_rows, len(items), index_digest), flush=True)
        return 0
    except (OSError, ValueError, EOFError, TimeoutError) as exc:
        print("B_SHARED_MEMORY_ERROR=1 detail=%s" % exc, flush=True)
        return 42
    finally:
        for handle, name in zip(handles, names):
            cleanup(handle, name)


if __name__ == "__main__":
    raise SystemExit(main())

