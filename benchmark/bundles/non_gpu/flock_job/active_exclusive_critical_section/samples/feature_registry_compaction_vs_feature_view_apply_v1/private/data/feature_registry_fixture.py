#!/usr/bin/env python3
import argparse
import hashlib
import hmac
import json
import os
import pathlib
import shutil
import sqlite3
import time


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


def write_json(path, value):
    path = pathlib.Path(path)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def sign_registry(registry_path, key_path):
    payload = pathlib.Path(registry_path).read_bytes()
    checksum = hashlib.sha256(payload).hexdigest()
    pathlib.Path(str(registry_path) + ".sha256").write_text(checksum + "\n", encoding="ascii")
    key = pathlib.Path(key_path).read_bytes().strip()
    signature = hmac.new(key, payload, hashlib.sha256).hexdigest()
    pathlib.Path(str(registry_path) + ".sig").write_text(signature + "\n", encoding="ascii")
    return checksum, signature


def replace_current(public_root, generation_dir):
    public_root = pathlib.Path(public_root)
    public_root.mkdir(parents=True, exist_ok=True)
    link = public_root / "current"
    tmp = public_root / f".current.{os.getpid()}.tmp"
    if tmp.exists() or tmp.is_symlink():
        tmp.unlink()
    os.symlink(generation_dir.resolve(), tmp)
    os.replace(tmp, link)


def preserve_lock_and_clear(root):
    root = pathlib.Path(root)
    lock_dir = root / ".locks"
    lock_dir.mkdir(parents=True, exist_ok=True)
    lock_path = lock_dir / "registry-update.lock"
    lock_path.touch(exist_ok=True)
    for child in list(root.iterdir()):
        if child.name == ".locks":
            continue
        if child.is_dir() and not child.is_symlink():
            shutil.rmtree(child)
        else:
            child.unlink(missing_ok=True)
    (root / "generations").mkdir(parents=True, exist_ok=True)
    (root / "public").mkdir(parents=True, exist_ok=True)
    (root / "run").mkdir(parents=True, exist_ok=True)
    (root / "sample_stats").mkdir(parents=True, exist_ok=True)
    return lock_path


def base_spec(index):
    entity = f"account_{index % 3}"
    source = f"serving_events_{index % 4}"
    return {
        "entity": entity,
        "entity_type": "account",
        "join_key": f"{entity}_id",
        "source": source,
        "source_path": f"/srv/feature-store/registry/sample_stats/{source}.json",
        "source_format": "parquet_stats",
        "feature_view": f"{source}_quality_{index:03d}",
        "window": f"{5 + index % 6}m",
        "features": [
            {"name": f"event_count_{index:03d}", "dtype": "int64"},
            {"name": f"score_mean_{index:03d}", "dtype": "float64"},
        ],
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


def reset(args):
    root = pathlib.Path(args.root)
    lock = preserve_lock_and_clear(root)
    for source_index in range(4):
        stats = {
            "source": f"serving_events_{source_index}",
            "row_count": 50000 + source_index * 1000,
            "columns": ["account_id", "event_count", "score"],
            "format": "parquet_stats",
        }
        write_json(root / "sample_stats" / f"serving_events_{source_index}.json", stats)
    write_json(
        root / "sample_stats" / "realtime_clickstream_stats.json",
        {
            "source": "realtime_clickstream_stats",
            "row_count": 184200,
            "columns": ["user_id", "clicks_10m", "purchases_10m", "distinct_sessions_10m"],
            "format": "parquet_stats",
        },
    )
    generation = "base-registry-20260726T000000Z"
    generation_dir = root / "generations" / generation
    generation_dir.mkdir(parents=True, exist_ok=True)
    db_path = generation_dir / "registry.db"
    connection = sqlite3.connect(db_path)
    try:
        init_schema(connection)
        for index in range(args.base_count):
            spec = base_spec(index)
            insert_spec(connection, spec, 50000 + index * 50)
        connection.execute("insert or replace into metadata(key, value) values (?, ?)", ("generation", generation))
        connection.execute("insert or replace into metadata(key, value) values (?, ?)", ("created_by", "fixture-reset"))
        connection.commit()
    finally:
        connection.close()
    registry_path = generation_dir / "registry.json"
    write_json(registry_path, registry_json_from_db(db_path, generation))
    sign_registry(registry_path, args.signing_key)
    replace_current(root / "public", generation_dir)
    print(f"FIXTURE_RESET_OK=1 ROOT={root} LOCK_INODE={lock.stat().st_ino} GENERATION={generation}")


def render_yaml(spec):
    lines = [
        f"entity: {spec['entity']}",
        f"entity_type: {spec['entity_type']}",
        f"join_key: {spec['join_key']}",
        f"source: {spec['source']}",
        f"source_path: {spec['source_path']}",
        f"source_format: {spec['source_format']}",
        f"feature_view: {spec['feature_view']}",
        f"window: {spec['window']}",
        "features:",
    ]
    for feature in spec["features"]:
        lines.append(f"  - {feature['name']}: {feature['dtype']}")
    return "\n".join(lines) + "\n"


def build_batch(args):
    output = pathlib.Path(args.output)
    if output.exists():
        shutil.rmtree(output)
    specs = output / "specs"
    stats_dir = output / "stats"
    specs.mkdir(parents=True)
    stats_dir.mkdir(parents=True)
    for index in range(args.count):
        spec = {
            "entity": f"model_subject_{index % 7}",
            "entity_type": "serving_subject",
            "join_key": f"subject_{index % 7}_id",
            "source": f"batch_training_stats_{index % 9}",
            "source_path": str(stats_dir / f"batch_training_stats_{index % 9}.json"),
            "source_format": "parquet_stats",
            "feature_view": f"calibration_signal_{index:04d}",
            "window": f"{10 + index % 12}m",
            "features": [
                {"name": f"score_p50_{index:04d}", "dtype": "float64"},
                {"name": f"score_p95_{index:04d}", "dtype": "float64"},
                {"name": f"events_{index:04d}", "dtype": "int64"},
            ],
        }
        (specs / f"{spec['feature_view']}.yaml").write_text(render_yaml(spec), encoding="utf-8")
    for source_index in range(9):
        write_json(
            stats_dir / f"batch_training_stats_{source_index}.json",
            {
                "source": f"batch_training_stats_{source_index}",
                "row_count": 76000 + source_index * 711,
                "columns": ["subject_id", "score_p50", "score_p95", "events"],
                "format": "parquet_stats",
            },
        )
    write_json(output / "batch_manifest.json", {"count": args.count, "created_at": time.time()})
    print(f"BATCH_BUILD_OK=1 OUTPUT={output} COUNT={args.count}")


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    reset_parser = sub.add_parser("reset")
    reset_parser.add_argument("--root", required=True)
    reset_parser.add_argument("--signing-key", required=True)
    reset_parser.add_argument("--base-count", type=int, default=8)
    batch_parser = sub.add_parser("build-batch")
    batch_parser.add_argument("--output", required=True)
    batch_parser.add_argument("--count", type=int, default=120)
    args = parser.parse_args()
    if args.command == "reset":
        reset(args)
    elif args.command == "build-batch":
        build_batch(args)


if __name__ == "__main__":
    main()

