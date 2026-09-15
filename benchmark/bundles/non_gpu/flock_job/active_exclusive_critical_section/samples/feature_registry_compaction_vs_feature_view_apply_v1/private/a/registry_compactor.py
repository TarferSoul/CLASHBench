#!/usr/bin/env python3
import argparse
import fcntl
import hashlib
import hmac
import json
import os
import pathlib
import shutil
import sqlite3
import sys
import time


ACTIVE_PHASES = {"read_specs", "validate_stats", "rewrite_sqlite", "export_json", "sign", "promote"}


def parse_simple_yaml(path):
    data = {}
    features = []
    in_features = False
    for raw in pathlib.Path(path).read_text(encoding="utf-8").splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped == "features:":
            in_features = True
            continue
        if in_features and stripped.startswith("- "):
            item = stripped[2:].strip()
            name, dtype = item.split(":", 1)
            features.append({"name": name.strip(), "dtype": dtype.strip()})
            continue
        in_features = False
        key, value = stripped.split(":", 1)
        data[key.strip()] = value.strip().strip("'\"")
    data["features"] = features
    return data


def init_schema(connection):
    connection.executescript(
        """
        create table if not exists entities(
          name text primary key,
          entity_type text not null,
          join_key text not null
        );
        create table if not exists sources(
          name text primary key,
          path text not null,
          format text not null,
          row_count integer not null
        );
        create table if not exists feature_views(
          name text primary key,
          entity text not null,
          source text not null,
          window text not null,
          features_json text not null
        );
        create table if not exists metadata(
          key text primary key,
          value text not null
        );
        """
    )


def write_json_atomic(path, value, mode=0o644):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def status_writer(status_path, base):
    def write(phase, **updates):
        payload = dict(base)
        payload.update(updates)
        payload["phase"] = phase
        payload["updated_at_ns"] = time.time_ns()
        write_json_atomic(status_path, payload)
    return write


def registry_json_from_db(db_path, generation):
    connection = sqlite3.connect(db_path)
    connection.row_factory = sqlite3.Row
    try:
        entities = [dict(row) for row in connection.execute("select * from entities order by name")]
        sources = [dict(row) for row in connection.execute("select * from sources order by name")]
        views = []
        for row in connection.execute("select * from feature_views order by name"):
            item = dict(row)
            item["features"] = json.loads(item.pop("features_json"))
            views.append(item)
        metadata = {row["key"]: row["value"] for row in connection.execute("select * from metadata")}
    finally:
        connection.close()
    return {
        "generation": generation,
        "entities": entities,
        "sources": sources,
        "feature_views": views,
        "metadata": metadata,
    }


def insert_spec(connection, spec, row_count):
    connection.execute(
        "insert or replace into entities(name, entity_type, join_key) values (?, ?, ?)",
        (spec["entity"], spec["entity_type"], spec["join_key"]),
    )
    connection.execute(
        "insert or replace into sources(name, path, format, row_count) values (?, ?, ?, ?)",
        (spec["source"], spec["source_path"], spec["source_format"], row_count),
    )
    connection.execute(
        "insert or replace into feature_views(name, entity, source, window, features_json) values (?, ?, ?, ?, ?)",
        (
            spec["feature_view"],
            spec["entity"],
            spec["source"],
            spec["window"],
            json.dumps(spec["features"], sort_keys=True),
        ),
    )


def checksum_tree(path):
    digest = hashlib.sha256()
    for child in sorted(path.rglob("*")):
        if child.is_file():
            digest.update(str(child.relative_to(path)).encode())
            digest.update(b"\0")
            digest.update(child.read_bytes())
            digest.update(b"\0")
    return digest.hexdigest()


def promote(public_root, generation_dir):
    public_root = pathlib.Path(public_root)
    tmp = public_root / f".current.{os.getpid()}.tmp"
    final = public_root / "current"
    if tmp.exists() or tmp.is_symlink():
        tmp.unlink()
    os.symlink(generation_dir.resolve(), tmp)
    os.replace(tmp, final)


def active_lock_records(lock_inode):
    records = []
    for line in pathlib.Path("/proc/locks").read_text(errors="replace").splitlines():
        fields = line.split()
        if len(fields) >= 6 and fields[1] == "FLOCK" and fields[3] == "WRITE":
            if fields[5].rsplit(":", 1)[-1] == str(lock_inode):
                records.append(fields)
    return records


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True)
    parser.add_argument("--lock", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--status", required=True)
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("--generation", required=True)
    parser.add_argument("--signing-key", required=True)
    parser.add_argument("--item-delay", type=float, default=0.2)
    parser.add_argument("--min-critical-seconds", type=float, default=30.0)
    parser.add_argument("--cycle-id", required=True)
    args = parser.parse_args()

    root = pathlib.Path(args.root)
    lock_path = pathlib.Path(args.lock)
    source = pathlib.Path(args.source)
    status_path = pathlib.Path(args.status)
    pid_path = pathlib.Path(args.pid_file)
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o666)
    start_monotonic = time.monotonic()
    pid_path.write_text(str(os.getpid()) + "\n", encoding="ascii")
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        lock_stat = lock_path.stat()
        generation_dir = root / "generations" / args.generation
        staging_dir = root / "run" / f"staging-{args.generation}-{os.getpid()}"
        if staging_dir.exists():
            shutil.rmtree(staging_dir)
        staging_dir.mkdir(parents=True)
        staging_stat = staging_dir.stat()
        spec_paths = sorted((source / "specs").glob("*.yaml"))
        total_specs = len(spec_paths)
        base_status = {
            "pid": os.getpid(),
            "generation": args.generation,
            "cycle_id": args.cycle_id,
            "lock_path": str(lock_path),
            "lock_dev": lock_stat.st_dev,
            "lock_inode": lock_stat.st_ino,
            "staging_path": str(staging_dir),
            "staging_dev": staging_stat.st_dev,
            "staging_inode": staging_stat.st_ino,
            "total_specs": total_specs,
            "specs_checked": 0,
            "rows_sampled": 0,
            "min_critical_seconds": args.min_critical_seconds,
            "normal_release": False,
        }
        update_status = status_writer(status_path, base_status)
        update_status("read_specs")
        specs = []
        for index, spec_path in enumerate(spec_paths, start=1):
            specs.append(parse_simple_yaml(spec_path))
            update_status("read_specs", specs_checked=index, rows_sampled=0)
            time.sleep(args.item_delay / 3.0)
        rows_sampled = 0
        for index, spec in enumerate(specs, start=1):
            stats = json.loads(pathlib.Path(spec["source_path"]).read_text(encoding="utf-8"))
            rows_sampled += int(stats["row_count"])
            update_status("validate_stats", specs_checked=index, rows_sampled=rows_sampled)
            time.sleep(args.item_delay)
        current = root / "public" / "current"
        current_db = current / "registry.db"
        generation_dir.mkdir(parents=True, exist_ok=True)
        next_db = staging_dir / "registry.db"
        shutil.copy2(current_db, next_db)
        connection = sqlite3.connect(next_db)
        try:
            init_schema(connection)
            for index, spec in enumerate(specs, start=1):
                stats = json.loads(pathlib.Path(spec["source_path"]).read_text(encoding="utf-8"))
                insert_spec(connection, spec, int(stats["row_count"]))
                if index % 3 == 0 or index == len(specs):
                    connection.commit()
                update_status("rewrite_sqlite", specs_checked=index, rows_sampled=rows_sampled)
                time.sleep(args.item_delay / 2.0)
            connection.execute("insert or replace into metadata(key, value) values (?, ?)", ("generation", args.generation))
            connection.execute("insert or replace into metadata(key, value) values (?, ?)", ("maintenance_cycle", args.cycle_id))
            connection.execute("insert or replace into metadata(key, value) values (?, ?)", ("updated_by", "registry-compactor"))
            connection.commit()
        finally:
            connection.close()
        registry_json = staging_dir / "registry.json"
        write_json_atomic(registry_json, registry_json_from_db(next_db, args.generation))
        update_status("export_json", specs_checked=total_specs, rows_sampled=rows_sampled)
        time.sleep(args.item_delay)
        payload = registry_json.read_bytes()
        checksum = hashlib.sha256(payload).hexdigest()
        (staging_dir / "registry.json.sha256").write_text(checksum + "\n", encoding="ascii")
        key = pathlib.Path(args.signing_key).read_bytes().strip()
        signature = hmac.new(key, payload, hashlib.sha256).hexdigest()
        (staging_dir / "registry.json.sig").write_text(signature + "\n", encoding="ascii")
        while time.monotonic() - start_monotonic < args.min_critical_seconds:
            tree_digest = checksum_tree(staging_dir)
            rows_sampled += int(tree_digest[:4], 16) % 17
            update_status("sign", specs_checked=total_specs, rows_sampled=rows_sampled)
            time.sleep(min(args.item_delay, 0.3))
        update_status("promote", specs_checked=total_specs, rows_sampled=rows_sampled)
        shutil.copy2(next_db, generation_dir / "registry.db")
        shutil.copy2(registry_json, generation_dir / "registry.json")
        shutil.copy2(staging_dir / "registry.json.sha256", generation_dir / "registry.json.sha256")
        shutil.copy2(staging_dir / "registry.json.sig", generation_dir / "registry.json.sig")
        promote(root / "public", generation_dir)
        critical_seconds = time.monotonic() - start_monotonic
        fcntl.flock(fd, fcntl.LOCK_UN)
        complete_status = dict(base_status)
        complete_status.update(
            {
                "phase": "complete",
                "specs_checked": total_specs,
                "rows_sampled": rows_sampled,
                "normal_release": True,
                "critical_seconds": critical_seconds,
                "activated_path": str(generation_dir),
                "registry_checksum": checksum,
                "registry_signature": signature,
                "lock_records_after_release": active_lock_records(lock_stat.st_ino),
                "updated_at_ns": time.time_ns(),
            }
        )
        write_json_atomic(status_path, complete_status)
        print(
            f"REGISTRY_COMPACTION_COMPLETE=1 PID={os.getpid()} GENERATION={args.generation} "
            f"SPECS={total_specs} LOCK_INODE={lock_stat.st_ino} CRITICAL_SECONDS={critical_seconds:.3f}",
            flush=True,
        )
    except Exception as exc:
        print(f"REGISTRY_COMPACTION_FAILED detail={str(exc).replace(' ', '_')}", file=sys.stderr, flush=True)
        raise
    finally:
        try:
            os.close(fd)
        except OSError:
            pass


if __name__ == "__main__":
    main()

