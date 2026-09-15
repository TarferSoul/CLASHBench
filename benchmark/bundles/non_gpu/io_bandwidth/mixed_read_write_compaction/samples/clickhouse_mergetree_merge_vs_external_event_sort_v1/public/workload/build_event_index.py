#!/usr/bin/env python3
import argparse
import hashlib
import heapq
import json
import os
import pathlib
import shutil
import sys
import time


def fsync_dir(path):
    fd = os.open(str(path), os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def durable_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    with tmp.open("rb") as handle:
        os.fsync(handle.fileno())
    tmp.replace(path)
    fsync_dir(path.parent)


def durable_rows(path, rows):
    path = pathlib.Path(path)
    tmp = path.with_name(path.name + ".tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    tmp.replace(path)
    fsync_dir(path.parent)


def drop_file_cache(path):
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


def payload_for(partition, row, payload_bytes):
    seed = hashlib.blake2b(f"partition={partition};row={row}".encode(), digest_size=32).hexdigest()
    repeated = (seed * ((payload_bytes // len(seed)) + 2))[:payload_bytes]
    return repeated


def create_fixture(args):
    input_dir = pathlib.Path(args.input)
    if input_dir.exists() and not input_dir.is_dir():
        raise SystemExit(f"input path is not a directory: {input_dir}")
    shutil.rmtree(input_dir, ignore_errors=True)
    input_dir.mkdir(parents=True, exist_ok=True)
    base_ts = 1730500000
    row_count = 0
    min_ts = None
    max_ts = None
    partition_meta = []
    for partition in range(args.partitions):
        path = input_dir / f"partition_{partition:03d}.jsonl"
        digest = hashlib.sha256()
        with path.open("w", encoding="utf-8") as handle:
            for row_index in range(args.rows_per_partition):
                logical = partition * args.rows_per_partition + row_index
                timestamp = base_ts + ((args.rows_per_partition - row_index) * 17 + partition * 911 + (row_index % 31) * 29)
                event = {
                    "timestamp": timestamp,
                    "event_id": f"evt-{partition:03d}-{row_index:06d}",
                    "service": f"svc-{(partition + row_index) % 17:02d}",
                    "severity": ["debug", "info", "warn", "error"][logical % 4],
                    "trace_id": hashlib.sha1(f"{partition}:{row_index}".encode()).hexdigest()[:24],
                    "payload": payload_for(partition, row_index, args.payload_bytes),
                }
                encoded = json.dumps(event, sort_keys=True, separators=(",", ":")) + "\n"
                digest.update(encoded.encode())
                handle.write(encoded)
                row_count += 1
                min_ts = timestamp if min_ts is None else min(min_ts, timestamp)
                max_ts = timestamp if max_ts is None else max(max_ts, timestamp)
            handle.flush()
            os.fsync(handle.fileno())
        drop_file_cache(path)
        partition_meta.append({"file": path.name, "rows": args.rows_per_partition, "sha256": digest.hexdigest()})
    fsync_dir(input_dir)
    durable_json(
        input_dir / "fixture_manifest.json",
        {
            "partition_count": args.partitions,
            "rows_per_partition": args.rows_per_partition,
            "row_count": row_count,
            "payload_bytes": args.payload_bytes,
            "min_timestamp": min_ts,
            "max_timestamp": max_ts,
            "partitions": partition_meta,
        },
    )
    if args.plan:
        plan = pathlib.Path(args.plan)
        durable_json(
            plan,
            {
                "input": str(pathlib.Path(args.input)),
                "scratch": str(pathlib.Path(args.scratch)),
                "output": str(pathlib.Path(args.output)),
                "summary": str(pathlib.Path(args.summary)),
                "objective_seconds": args.objective_seconds,
                "expected_partition_count": args.partitions,
                "expected_row_count": row_count,
            },
        )


def read_partition(path):
    rows = []
    with pathlib.Path(path).open("r", encoding="utf-8") as handle:
        for line in handle:
            if line.strip():
                rows.append(json.loads(line))
    drop_file_cache(path)
    return rows


def merge_runs(run_paths, output_path):
    handles = []
    heap = []
    digest = hashlib.sha256()
    row_count = 0
    min_ts = None
    max_ts = None
    last_key = None
    sorted_ok = True
    try:
        for index, path in enumerate(run_paths):
            handle = pathlib.Path(path).open("r", encoding="utf-8")
            handles.append(handle)
            line = handle.readline()
            if line:
                row = json.loads(line)
                heapq.heappush(heap, ((row["timestamp"], row["event_id"]), index, row))
        tmp = pathlib.Path(output_path).with_name(pathlib.Path(output_path).name + ".tmp")
        with tmp.open("w", encoding="utf-8") as out:
            while heap:
                key, index, row = heapq.heappop(heap)
                if last_key is not None and key < last_key:
                    sorted_ok = False
                last_key = key
                encoded = json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n"
                out.write(encoded)
                digest.update(encoded.encode())
                row_count += 1
                ts = row["timestamp"]
                min_ts = ts if min_ts is None else min(min_ts, ts)
                max_ts = ts if max_ts is None else max(max_ts, ts)
                nxt = handles[index].readline()
                if nxt:
                    next_row = json.loads(nxt)
                    heapq.heappush(heap, ((next_row["timestamp"], next_row["event_id"]), index, next_row))
            out.flush()
            os.fsync(out.fileno())
        tmp.replace(output_path)
        fsync_dir(pathlib.Path(output_path).parent)
    finally:
        for handle in handles:
            handle.close()
        for path in run_paths:
            drop_file_cache(path)
    drop_file_cache(output_path)
    return {
        "row_count": row_count,
        "min_timestamp": min_ts,
        "max_timestamp": max_ts,
        "checksum": digest.hexdigest(),
        "sorted_ok": sorted_ok,
    }


def validate_output(path, expected_rows, expected_checksum):
    digest = hashlib.sha256()
    count = 0
    last_key = None
    sorted_ok = True
    with pathlib.Path(path).open("r", encoding="utf-8") as handle:
        for line in handle:
            if not line:
                continue
            digest.update(line.encode())
            row = json.loads(line)
            key = (row["timestamp"], row["event_id"])
            if last_key is not None and key < last_key:
                sorted_ok = False
            last_key = key
            count += 1
    drop_file_cache(path)
    return count == expected_rows and digest.hexdigest() == expected_checksum and sorted_ok


def run_build(args):
    started = time.monotonic()
    input_dir = pathlib.Path(args.input)
    scratch = pathlib.Path(args.scratch)
    output = pathlib.Path(args.output)
    summary = pathlib.Path(args.summary)
    plan = {}
    if args.plan and pathlib.Path(args.plan).exists():
        plan = json.loads(pathlib.Path(args.plan).read_text())
    objective = float(args.objective_seconds or plan.get("objective_seconds") or 0.0)
    shutil.rmtree(scratch, ignore_errors=True)
    scratch.mkdir(parents=True, exist_ok=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    manifest_path = input_dir / "fixture_manifest.json"
    fixture_manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else {}
    input_paths = sorted(input_dir.glob("partition_*.jsonl"))
    run_paths = []
    total_rows = 0
    for run_index, path in enumerate(input_paths):
        rows = read_partition(path)
        rows.sort(key=lambda item: (item["timestamp"], item["event_id"]))
        run_path = scratch / f"sorted_run_{run_index:03d}.jsonl"
        durable_rows(run_path, rows)
        run_paths.append(run_path)
        total_rows += len(rows)
    merged = merge_runs(run_paths, output)
    validation_ok = validate_output(output, merged["row_count"], merged["checksum"])
    elapsed = time.monotonic() - started
    expected_partitions = int(fixture_manifest.get("partition_count") or len(input_paths))
    expected_rows = int(fixture_manifest.get("row_count") or total_rows)
    report = {
        "input_partition_count": len(input_paths),
        "row_count": merged["row_count"],
        "min_timestamp": merged["min_timestamp"],
        "max_timestamp": merged["max_timestamp"],
        "sorted_run_count": len(run_paths),
        "checksum": merged["checksum"],
        "validation_ok": bool(validation_ok and merged["sorted_ok"] and len(input_paths) == expected_partitions and merged["row_count"] == expected_rows),
        "objective_seconds": objective,
        "elapsed_seconds": elapsed,
        "objective_met": bool(objective <= 0 or elapsed <= objective),
        "scratch_path": str(scratch),
        "output_path": str(output),
        "input_path": str(input_dir),
        "expected_row_count": expected_rows,
    }
    durable_json(summary, report)
    return 0 if report["validation_ok"] else 4


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--create-fixture", action="store_true")
    parser.add_argument("--input", required=True)
    parser.add_argument("--scratch", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--summary", required=True)
    parser.add_argument("--plan", default="")
    parser.add_argument("--partitions", type=int, default=6)
    parser.add_argument("--rows-per-partition", type=int, default=6200)
    parser.add_argument("--payload-bytes", type=int, default=420)
    parser.add_argument("--objective-seconds", type=float, default=14.0)
    args = parser.parse_args()
    if args.create_fixture:
        create_fixture(args)
        return 0
    return run_build(args)


if __name__ == "__main__":
    raise SystemExit(main())
