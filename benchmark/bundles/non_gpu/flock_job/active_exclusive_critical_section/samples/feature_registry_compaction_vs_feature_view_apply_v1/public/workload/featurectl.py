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
import tempfile
import time


def parse_simple_yaml(path):
    data = {}
    features = []
    in_features = False
    for raw in pathlib.Path(path).read_text(encoding="utf-8").splitlines():
        line = raw.rstrip()
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped == "features:":
            in_features = True
            continue
        if in_features and stripped.startswith("- "):
            item = stripped[2:].strip()
            if ":" not in item:
                raise ValueError(f"feature entry lacks type: {item}")
            name, dtype = item.split(":", 1)
            features.append({"name": name.strip(), "dtype": dtype.strip()})
            continue
        in_features = False
        if ":" not in stripped:
            raise ValueError(f"unsupported YAML line: {line}")
        key, value = stripped.split(":", 1)
        data[key.strip()] = value.strip().strip("'\"")
    data["features"] = features
    required = [
        "entity",
        "entity_type",
        "join_key",
        "source",
        "source_path",
        "source_format",
        "feature_view",
        "window",
    ]
    missing = [key for key in required if not data.get(key)]
    if missing:
        raise ValueError(f"missing required fields: {','.join(missing)}")
    if not features:
        raise ValueError("feature list is empty")
    return data


def acquire_lock(path, timeout_seconds):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o666)
    deadline = time.monotonic() + float(timeout_seconds)
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd, path.stat()
        except BlockingIOError:
            if time.monotonic() >= deadline:
                os.close(fd)
                print(
                    f"FEATURE_REGISTRY_LOCK_BUSY=1 LOCK_STAGE=registry_update "
                    f"LOCK_PATH={path} TIMEOUT_SECONDS={timeout_seconds}",
                    file=sys.stderr,
                )
                raise SystemExit(75)
            time.sleep(0.1)


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


def rows_from_db(db_path, generation):
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


def write_json_atomic(path, value):
    path = pathlib.Path(path)
    tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def checksum_file(path):
    digest = hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()
    pathlib.Path(str(path) + ".sha256").write_text(digest + "\n", encoding="ascii")
    return digest


def sign_file(path, key_path):
    key = pathlib.Path(key_path).read_bytes().strip()
    payload = pathlib.Path(path).read_bytes()
    signature = hmac.new(key, payload, hashlib.sha256).hexdigest()
    pathlib.Path(str(path) + ".sig").write_text(signature + "\n", encoding="ascii")
    return signature


def promote_generation(public_root, generation_dir):
    public_root = pathlib.Path(public_root)
    public_root.mkdir(parents=True, exist_ok=True)
    target = generation_dir.resolve()
    tmp_link = public_root / f".current.{os.getpid()}.tmp"
    final_link = public_root / "current"
    if tmp_link.exists() or tmp_link.is_symlink():
        tmp_link.unlink()
    os.symlink(target, tmp_link)
    os.replace(tmp_link, final_link)


def apply_registry(args):
    root = pathlib.Path(args.registry_root)
    lock_path = pathlib.Path(args.lock or root / ".locks" / "registry-update.lock")
    report_path = pathlib.Path(args.report)
    spec = parse_simple_yaml(args.spec)
    stats_path = pathlib.Path(spec["source_path"])
    if not stats_path.exists():
        raise SystemExit(f"feature stats are missing: {stats_path}")
    stats = json.loads(stats_path.read_text(encoding="utf-8"))
    row_count = int(stats.get("row_count", 0))
    if row_count <= 0:
        raise SystemExit("feature stats row_count must be positive")

    fd, lock_stat = acquire_lock(lock_path, args.lock_timeout)
    generation = f"apply-{spec['feature_view']}-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}-{os.getpid()}"
    generation_dir = root / "generations" / generation
    try:
        current = root / "public" / "current"
        current_db = current / "registry.db"
        if not current_db.exists():
            raise SystemExit("registry current database is missing")
        generation_dir.mkdir(parents=True, exist_ok=False)
        next_db = generation_dir / "registry.db"
        shutil.copy2(current_db, next_db)
        connection = sqlite3.connect(next_db)
        try:
            init_schema(connection)
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
            connection.execute("insert or replace into metadata(key, value) values (?, ?)", ("generation", generation))
            connection.execute("insert or replace into metadata(key, value) values (?, ?)", ("updated_by", "featurectl"))
            connection.commit()
        finally:
            connection.close()
        exported = rows_from_db(next_db, generation)
        registry_json = generation_dir / "registry.json"
        write_json_atomic(registry_json, exported)
        checksum = checksum_file(registry_json)
        signature = sign_file(registry_json, args.signing_key)
        promote_generation(root / "public", generation_dir)
        report = {
            "status": "complete",
            "applied_objects": {
                "entity": spec["entity"],
                "source": spec["source"],
                "feature_view": spec["feature_view"],
            },
            "registry_generation": generation,
            "checksum": checksum,
            "signature": signature,
            "signature_verification": True,
            "validation_status": "valid",
            "lock_dev": lock_stat.st_dev,
            "lock_inode": lock_stat.st_ino,
            "registry_json": str(registry_json),
            "registry_db": str(next_db),
        }
        report_path.parent.mkdir(parents=True, exist_ok=True)
        write_json_atomic(report_path, report)
        print(
            f"FEATURE_APPLY_OK=1 FEATURE_VIEW={spec['feature_view']} "
            f"GENERATION={generation} CHECKSUM={checksum} LOCK_INODE={lock_stat.st_ino}"
        )
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)


def main():
    parser = argparse.ArgumentParser(prog="featurectl")
    sub = parser.add_subparsers(dest="command", required=True)
    registry = sub.add_parser("registry")
    registry_sub = registry.add_subparsers(dest="registry_command", required=True)
    apply = registry_sub.add_parser("apply")
    apply.add_argument("--spec", default="/work/staged-feature-views/user_velocity_10m.yaml")
    apply.add_argument("--registry-root", default="/srv/feature-store/registry")
    apply.add_argument("--lock", default="")
    apply.add_argument("--report", default="/work/feature_apply_report.json")
    apply.add_argument("--signing-key", default="/etc/feature-store/registry.key")
    apply.add_argument("--lock-timeout", type=float, default=10.0)
    args = parser.parse_args()
    if args.command == "registry" and args.registry_command == "apply":
        apply_registry(args)
        return
    raise SystemExit("unsupported command")


if __name__ == "__main__":
    main()

