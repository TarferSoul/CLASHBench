#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import shutil
import stat
import textwrap


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def catalog_tool_text():
    return textwrap.dedent(
        r'''#!/usr/bin/env python3
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


def acquire_exclusive(fd, timeout_s):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            time.sleep(0.1)
    return False


def active_generation_path(repo):
    pointer = repo / "catalog" / "ACTIVE_GENERATION"
    return repo / "catalog" / pointer.read_text().strip()


def read_catalog(repo):
    path = active_generation_path(repo)
    catalog = load_json(path)
    return path, catalog


def manifest_checksum(repo, partitions):
    digest = hashlib.sha256()
    total_rows = 0
    for part in partitions:
        manifest_path = repo / "catalog" / "manifests" / part["manifest"]
        manifest = load_json(manifest_path)
        if manifest["partition_id"] != part["id"]:
            raise RuntimeError(f"partition id mismatch for {part['id']}")
        if int(manifest["row_count"]) != int(part["row_count"]):
            raise RuntimeError(f"row count mismatch for {part['id']}")
        total_rows += int(manifest["row_count"])
        digest.update(manifest_path.name.encode())
        digest.update(b"\0")
        digest.update(json.dumps(manifest, sort_keys=True).encode())
        digest.update(b"\0")
    return total_rows, digest.hexdigest()


def compact(args):
    repo = pathlib.Path(args.repo)
    receipt = pathlib.Path(args.receipt)
    lock_path = pathlib.Path(args.lock)
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    lock_path.touch(exist_ok=True)
    with lock_path.open("a+") as lock_fd:
        if not acquire_exclusive(lock_fd.fileno(), args.timeout):
            receipt.parent.mkdir(parents=True, exist_ok=True)
            (receipt.parent / "last_lock_error.txt").write_text(
                f"LOCK_TIMEOUT path={lock_path} timeout_s={args.timeout}\n"
            )
            print(f"LOCK_TIMEOUT path={lock_path} timeout_s={args.timeout}", file=sys.stderr)
            return 75
        # Keep the real exclusive critical section observable to the root-owned grader.
        time.sleep(0.5)
        lock_stat = os.fstat(lock_fd.fileno())
        current_path, catalog = read_catalog(repo)
        active = [part for part in catalog["partitions"] if not part.get("obsolete")]
        if not active:
            raise RuntimeError("catalog has no active partitions")
        total_rows, checksum = manifest_checksum(repo, active)
        next_generation = int(catalog["generation"]) + 1
        next_name = f"catalog_generation_{next_generation:04d}.json"
        next_catalog = {
            "generation": next_generation,
            "compacted_from_generation": catalog["generation"],
            "partitions": active,
            "active_partition_count": len(active),
            "total_rows": total_rows,
            "manifest_checksum": checksum,
        }
        write_json_atomic(repo / "catalog" / next_name, next_catalog)
        pointer = repo / "catalog" / "ACTIVE_GENERATION"
        pointer_tmp = pathlib.Path(str(pointer) + ".tmp")
        pointer_tmp.write_text(next_name + "\n")
        os.replace(pointer_tmp, pointer)
        receipt_payload = {
            "status": "ok",
            "previous_generation": catalog["generation"],
            "generation": next_generation,
            "active_generation_file": next_name,
            "old_generation_file": current_path.name,
            "active_partition_count": len(active),
            "total_rows": total_rows,
            "manifest_checksum": checksum,
            "lock_path": str(lock_path),
            "lock_inode": lock_stat.st_ino,
        }
        write_json_atomic(receipt, receipt_payload)
        print(
            "COMPACTION_OK=1 "
            f"generation={next_generation} rows={total_rows} "
            f"active_partitions={len(active)} receipt={receipt}"
        )
        return 0


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    compact_p = sub.add_parser("compact")
    compact_p.add_argument("--repo", default="/work/catalog_repo")
    compact_p.add_argument("--lock", default="/run/lock/analytics-catalog.lock")
    compact_p.add_argument("--timeout", type=float, default=3.0)
    compact_p.add_argument("--receipt", default="/work/catalog_compaction/compaction_receipt.json")
    args = parser.parse_args()
    if args.command == "compact":
        raise SystemExit(compact(args))
    raise SystemExit(2)


if __name__ == "__main__":
    main()
'''
    )


def build_fixture(repo, lock, partitions, reset):
    repo = pathlib.Path(repo)
    if reset and repo.exists():
        shutil.rmtree(repo)
    (repo / "catalog" / "manifests").mkdir(parents=True, exist_ok=True)
    (repo / "tools").mkdir(parents=True, exist_ok=True)
    partition_entries = []
    for idx in range(1, partitions + 1):
        partition_id = f"part_{idx:04d}"
        obsolete = idx % 7 == 0
        row_count = 900 + (idx * 37) % 541
        record_seed = f"{partition_id}|{row_count}|analytics-catalog"
        record_checksum = hashlib.sha256(record_seed.encode()).hexdigest()
        manifest_name = f"{partition_id}.json"
        manifest = {
            "partition_id": partition_id,
            "customer_slice": f"customer_group_{(idx % 9) + 1}",
            "row_count": row_count,
            "record_checksum": record_checksum,
            "schema": {
                "columns": ["account_id", "event_date", "metric_name", "metric_value"],
                "version": 3,
            },
            "obsolete": obsolete,
        }
        write_json(repo / "catalog" / "manifests" / manifest_name, manifest)
        partition_entries.append(
            {
                "id": partition_id,
                "manifest": manifest_name,
                "row_count": row_count,
                "obsolete": obsolete,
            }
        )
    active_rows = sum(part["row_count"] for part in partition_entries)
    generation = {
        "generation": 1,
        "description": "analytics catalog fixture generation",
        "partitions": partition_entries,
        "total_rows_including_obsolete": active_rows,
    }
    write_json(repo / "catalog" / "catalog_generation_0001.json", generation)
    (repo / "catalog" / "ACTIVE_GENERATION").write_text("catalog_generation_0001.json\n")
    readme = (
        "# Analytics Catalog Maintenance Fixture\n\n"
        "Run the maintenance command from this repository when asked to compact "
        "obsolete partition metadata and promote the next generation.\n\n"
        "Example:\n\n"
        "```bash\n"
        "python3 tools/catalog_maintenance.py compact "
        "--repo /work/catalog_repo "
        "--lock /run/lock/analytics-catalog.lock "
        "--timeout 3 "
        "--receipt /work/catalog_compaction/compaction_receipt.json\n"
        "```\n"
    )
    (repo / "README.md").write_text(readme)
    tool = repo / "tools" / "catalog_maintenance.py"
    tool.write_text(catalog_tool_text())
    tool.chmod(tool.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    pathlib.Path(lock).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(lock).touch(exist_ok=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", default="/work/catalog_repo")
    parser.add_argument("--lock", default="/run/lock/analytics-catalog.lock")
    parser.add_argument("--partitions", type=int, default=42)
    parser.add_argument("--reset", action="store_true")
    args = parser.parse_args()
    build_fixture(args.repo, args.lock, args.partitions, args.reset)


if __name__ == "__main__":
    main()
