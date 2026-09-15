#!/usr/bin/env python3
import argparse
import fcntl
import hashlib
import json
import os
import pathlib
import sys
import time


def load_json(path):
    return json.loads(pathlib.Path(path).read_text())


def write_json_atomic(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = pathlib.Path(str(path) + ".tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, path)


def proc_start_time(pid):
    stat = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    return int(stat[21])


def active_catalog(repo):
    pointer = repo / "catalog" / "ACTIVE_GENERATION"
    generation_file = pointer.read_text().strip()
    return generation_file, load_json(repo / "catalog" / generation_file)


def heavy_manifest_digest(payload):
    digest = hashlib.sha256(payload).digest()
    for _ in range(120):
        digest = hashlib.sha256(digest + payload).digest()
    return hashlib.sha256(digest).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--worker-id", required=True)
    parser.add_argument("--role", required=True)
    parser.add_argument("--repo", default="/work/catalog_repo")
    parser.add_argument("--lock", default="/run/lock/analytics-catalog.lock")
    parser.add_argument("--state-dir", default="/run/analytics_catalog_exports")
    parser.add_argument("--export-dir", default="/var/tmp/catalog_exports")
    parser.add_argument("--throttle", type=float, default=0.8)
    args = parser.parse_args()

    repo = pathlib.Path(args.repo)
    state_dir = pathlib.Path(args.state_dir)
    export_dir = pathlib.Path(args.export_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    export_dir.mkdir(parents=True, exist_ok=True)
    lock_path = pathlib.Path(args.lock)
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    lock_path.touch(exist_ok=True)

    pid = os.getpid()
    start_time = proc_start_time(pid)
    csv_path = export_dir / f"{args.worker_id}.csv"
    done_path = state_dir / f"{args.worker_id}.done.json"
    progress_path = state_dir / f"{args.worker_id}.progress.json"
    ready_path = state_dir / f"{args.worker_id}.ready.json"

    with lock_path.open("a+") as lock_fd:
        fcntl.flock(lock_fd.fileno(), fcntl.LOCK_SH)
        lock_stat = os.fstat(lock_fd.fileno())
        generation_file, catalog = active_catalog(repo)
        ready = {
            "pid": pid,
            "start_time": start_time,
            "worker_id": args.worker_id,
            "role": args.role,
            "generation_file": generation_file,
            "lock_path": str(lock_path),
            "lock_inode": lock_stat.st_ino,
            "lock_device": lock_stat.st_dev,
            "ready_at": time.time(),
        }
        write_json_atomic(ready_path, ready)
        rows_written = 0
        partitions_processed = 0
        export_digest = hashlib.sha256()
        with csv_path.open("w") as csv:
            csv.write("worker_id,role,generation,partition_id,row_count,manifest_digest\n")
            csv.flush()
            os.fsync(csv.fileno())
            for part in catalog["partitions"]:
                manifest_path = repo / "catalog" / "manifests" / part["manifest"]
                payload = manifest_path.read_bytes()
                manifest = json.loads(payload)
                if manifest["partition_id"] != part["id"]:
                    raise RuntimeError(f"partition mismatch for {part['id']}")
                if int(manifest["row_count"]) != int(part["row_count"]):
                    raise RuntimeError(f"row-count mismatch for {part['id']}")
                digest = heavy_manifest_digest(payload)
                csv.write(
                    f"{args.worker_id},{args.role},{catalog['generation']},"
                    f"{part['id']},{part['row_count']},{digest}\n"
                )
                csv.flush()
                os.fsync(csv.fileno())
                export_digest.update(digest.encode())
                rows_written += int(part["row_count"])
                partitions_processed += 1
                write_json_atomic(
                    progress_path,
                    {
                        "pid": pid,
                        "start_time": start_time,
                        "worker_id": args.worker_id,
                        "role": args.role,
                        "phase": "streaming_export",
                        "partitions_processed": partitions_processed,
                        "rows_written": rows_written,
                        "generation_file": generation_file,
                        "csv_path": str(csv_path),
                        "updated_at": time.time(),
                    },
                )
                time.sleep(args.throttle)
            csv.write(
                f"{args.worker_id},{args.role},{catalog['generation']},"
                f"EXPORT_FOOTER,{rows_written},{export_digest.hexdigest()}\n"
            )
            csv.flush()
            os.fsync(csv.fileno())
        sidecar = csv_path.with_suffix(".sha256")
        sidecar.write_text(export_digest.hexdigest() + "\n")
        write_json_atomic(
            done_path,
            {
                "pid": pid,
                "start_time": start_time,
                "worker_id": args.worker_id,
                "role": args.role,
                "status": "complete",
                "partitions_processed": partitions_processed,
                "rows_written": rows_written,
                "csv_path": str(csv_path),
                "checksum_path": str(sidecar),
                "generation_file": generation_file,
                "finished_at": time.time(),
            },
        )
        write_json_atomic(
            progress_path,
            {
                "pid": pid,
                "start_time": start_time,
                "worker_id": args.worker_id,
                "role": args.role,
                "phase": "complete",
                "partitions_processed": partitions_processed,
                "rows_written": rows_written,
                "generation_file": generation_file,
                "csv_path": str(csv_path),
                "updated_at": time.time(),
            },
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

