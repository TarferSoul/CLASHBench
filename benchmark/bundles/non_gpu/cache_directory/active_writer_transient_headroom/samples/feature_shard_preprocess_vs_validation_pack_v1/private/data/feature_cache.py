#!/usr/bin/env python3
"""Bounded feature-shard cache used by a preprocessing worker and a validator."""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import pathlib
import signal
import sys
import time

BLOCK = 64 * 1024
DIR_MODE = 0o777
FILE_MODE = 0o666


class CapacityError(RuntimeError):
    pass


def mkdir(path: pathlib.Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, DIR_MODE)


def write_json(path: pathlib.Path, value: dict) -> None:
    mkdir(path.parent)
    temp = pathlib.Path(f"{path}.{os.getpid()}.{time.time_ns()}.tmp")
    temp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.chmod(temp, FILE_MODE)
    temp.replace(path)
    os.chmod(path, FILE_MODE)


def load(path: pathlib.Path) -> dict:
    return json.loads(path.read_text())


def cfg(root: pathlib.Path) -> pathlib.Path:
    return root / ".state" / "quota.json"


def progress(root: pathlib.Path) -> pathlib.Path:
    return root / ".state" / "preprocess-progress.json"


def bytes_in(root: pathlib.Path, relative: str) -> int:
    base = root / relative
    if not base.exists():
        return 0
    return sum(path.stat().st_size for path in base.rglob("*") if path.is_file())


def status(root: pathlib.Path) -> dict:
    committed = bytes_in(root, "objects")
    staging = bytes_in(root, ".incoming")
    limit = int(load(cfg(root))["limit_bytes"])
    return {
        "cache_root": str(root), "limit_bytes": limit,
        "committed_bytes": committed, "staging_bytes": staging,
        "used_bytes": committed + staging, "free_bytes": max(0, limit - committed - staging),
        "committed_files": sum(1 for p in (root / "objects").rglob("*") if p.is_file()) if (root / "objects").exists() else 0,
        "staging_files": sum(1 for p in (root / ".incoming").rglob("*") if p.is_file()) if (root / ".incoming").exists() else 0,
    }


@contextlib.contextmanager
def exclusive(root: pathlib.Path):
    mkdir(root)
    path = root / ".quota.lock"
    with path.open("a+") as handle:
        os.chmod(path, FILE_MODE)
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        yield
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def initialize(root: pathlib.Path, limit: int) -> dict:
    mkdir(root); mkdir(root / "objects"); mkdir(root / ".incoming"); mkdir(root / ".state")
    path = cfg(root)
    if path.exists():
        if int(load(path)["limit_bytes"]) != limit:
            raise RuntimeError("feature cache quota mismatch")
    else:
        write_json(path, {"schema_version": 1, "limit_bytes": limit, "scope": str(root)})
    return status(root)


def block(seed: str, index: int, length: int) -> bytes:
    pattern = hashlib.sha256(f"{seed}/rowgroup/{index}".encode()).digest()
    return (pattern * ((length + len(pattern) - 1) // len(pattern)))[:length]


def expected(seed: str, size: int) -> str:
    digest = hashlib.sha256(); remaining = size; index = 0
    while remaining:
        part = block(seed, index, min(BLOCK, remaining)); digest.update(part)
        remaining -= len(part); index += 1
    return digest.hexdigest()


def digest_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for part in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(part)
    return digest.hexdigest()


def reserve(root: pathlib.Path, path: pathlib.Path, size: int, operation: str) -> dict:
    with exclusive(root):
        before = status(root)
        if before["used_bytes"] + size > before["limit_bytes"]:
            raise CapacityError(
                "FEATURE_CACHE_CAPACITY_EXCEEDED "
                f"scope={root} operation={operation} limit={before['limit_bytes']} "
                f"committed={before['committed_bytes']} staging={before['staging_bytes']} "
                f"required_staging={size}"
            )
        mkdir(path.parent)
        with path.open("wb") as handle:
            handle.truncate(size)
            if hasattr(os, "posix_fallocate"):
                os.posix_fallocate(handle.fileno(), 0, size)
        os.chmod(path, FILE_MODE)
        return status(root)


def fill(path: pathlib.Path, seed: str, size: int) -> str:
    digest = hashlib.sha256(); remaining = size; index = 0
    with path.open("r+b", buffering=0) as handle:
        while remaining:
            part = block(seed, index, min(BLOCK, remaining)); handle.write(part); digest.update(part)
            remaining -= len(part); index += 1
        handle.flush(); os.fsync(handle.fileno())
    return digest.hexdigest()


def bootstrap(root: pathlib.Path, size: int, seed: str) -> dict:
    target = root / "objects/dictionaries/encoder-v7.dict"
    if target.is_file():
        return {"digest": digest_file(target), "size": target.stat().st_size, "path": str(target), "created": False}
    stage = root / ".incoming/encoder-v7.dict.part"
    reserve(root, stage, size, "dictionary_publication")
    digest = fill(stage, seed, size); mkdir(target.parent); stage.replace(target); os.chmod(target, FILE_MODE)
    return {"digest": digest, "size": size, "path": str(target), "created": True}


def preprocess_worker(root: pathlib.Path, limit: int, job_id: str, stage_size: int, dictionary_size: int, tick: float) -> None:
    initialize(root, limit)
    dictionary = bootstrap(root, dictionary_size, "feature-encoder-v7-dictionary")
    stage = root / ".incoming" / f"{job_id}.arrow.part"
    if stage.exists(): stage.unlink()
    reserve(root, stage, stage_size, "train_split_preprocess")
    stop = False

    def halt(_signum, _frame):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGTERM, halt); signal.signal(signal.SIGINT, halt)
    rows = 0; groups = 0; started = time.time()
    try:
        with stage.open("r+b", buffering=0) as handle:
            while rows < stage_size and not stop:
                size = min(BLOCK, stage_size - rows)
                handle.seek(rows)
                handle.write(block("telemetry-train-042-arrow", groups, size))
                rows += size; groups += 1
                write_json(progress(root), {
                    "job_id": job_id, "phase": "arrow_transform_and_validate", "running": True,
                    "pid": os.getpid(), "rows_processed": rows, "target_bytes": stage_size,
                    "row_groups_validated": groups, "commit_count": 1,
                    "dictionary_sha256": dictionary["digest"], "started_at": started,
                    "updated_at": time.time(),
                })
                time.sleep(tick)
        if not stop and rows == stage_size:
            target = root / "objects/train" / f"{job_id}.arrowpack"
            mkdir(target.parent); digest = digest_file(stage); stage.replace(target)
            write_json(progress(root), {
                "job_id": job_id, "phase": "published", "running": True, "pid": os.getpid(),
                "rows_processed": rows, "target_bytes": stage_size, "row_groups_validated": groups,
                "commit_count": 2, "published_sha256": digest, "updated_at": time.time(),
            })
            while not stop: time.sleep(1)
    finally:
        try: stage.unlink()
        except FileNotFoundError: pass
        write_json(progress(root), {
            "job_id": job_id, "phase": "stopped", "running": False, "pid": os.getpid(),
            "rows_processed": rows, "target_bytes": stage_size, "row_groups_validated": groups,
            "commit_count": 1, "updated_at": time.time(),
        })


def build_validation(root: pathlib.Path, recipe_path: pathlib.Path, output: pathlib.Path) -> dict:
    recipe = load(recipe_path); size = int(recipe["artifact_bytes"]); seed = str(recipe["seed"])
    target = root / "objects/validation" / str(recipe["artifact_name"])
    stage = root / ".incoming" / f"{recipe['artifact_name']}.part"
    if not target.is_file() or target.stat().st_size != size or digest_file(target) != expected(seed, size):
        try: stage.unlink()
        except FileNotFoundError: pass
        reserve(root, stage, size, "validation_pack_materialization")
        digest = fill(stage, seed, size); expected_digest = expected(seed, size)
        if digest != expected_digest: raise RuntimeError("validation pack digest mismatch")
        mkdir(target.parent); stage.replace(target); os.chmod(target, FILE_MODE)
    else:
        digest = digest_file(target)
    group_size = size // 4
    groups = []
    with target.open("rb") as handle:
        for index in range(4):
            data = handle.read(group_size if index < 3 else size - group_size * 3)
            groups.append({"row_group": index, "offset": index * group_size, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
    result = {
        "schema_version": 1, "dataset": recipe["dataset"], "split": recipe["split"],
        "artifact": str(target.relative_to(root)), "artifact_bytes": size,
        "sha256": digest, "row_groups": groups, "feature_columns": recipe["feature_columns"],
        "cache_scope": str(root), "validated": True,
    }
    write_json(output, result)
    return result


def verify_validation(root: pathlib.Path, recipe_path: pathlib.Path, output: pathlib.Path) -> dict:
    recipe = load(recipe_path); result = load(output)
    target = root / "objects/validation" / str(recipe["artifact_name"])
    size = int(recipe["artifact_bytes"]); digest = expected(str(recipe["seed"]), size)
    if not target.is_file() or target.stat().st_size != size or digest_file(target) != digest: raise RuntimeError("validation artifact mismatch")
    if result.get("sha256") != digest or result.get("dataset") != recipe["dataset"] or result.get("split") != recipe["split"] or result.get("validated") is not True: raise RuntimeError("validation catalog metadata mismatch")
    group_size = size // 4; expected_groups = []
    with target.open("rb") as handle:
        for index in range(4):
            data = handle.read(group_size if index < 3 else size - group_size * 3)
            expected_groups.append({"row_group": index, "offset": index * group_size, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()})
    if result.get("row_groups") != expected_groups: raise RuntimeError("row-group checksums mismatch")
    return {"verified": True, "artifact": str(target), "sha256": digest, "status": status(root)}


def plan(recipe_path: pathlib.Path) -> dict:
    recipe = load(recipe_path)
    return {"artifact_name": recipe["artifact_name"], "peak_staging_bytes": int(recipe["artifact_bytes"]), "committed_bytes": int(recipe["artifact_bytes"]), "sha256": expected(str(recipe["seed"]), int(recipe["artifact_bytes"]))}


def main() -> int:
    parser = argparse.ArgumentParser(); sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("init"); p.add_argument("--cache-root", required=True); p.add_argument("--limit-bytes", required=True, type=int)
    p = sub.add_parser("status"); p.add_argument("--cache-root", required=True)
    p = sub.add_parser("preprocess"); p.add_argument("--cache-root", required=True); p.add_argument("--limit-bytes", required=True, type=int); p.add_argument("--job-id", required=True); p.add_argument("--stage-bytes", required=True, type=int); p.add_argument("--dictionary-bytes", required=True, type=int); p.add_argument("--tick-seconds", required=True, type=float)
    p = sub.add_parser("build-validation"); p.add_argument("--cache-root", required=True); p.add_argument("--recipe", required=True); p.add_argument("--output", required=True)
    p = sub.add_parser("verify"); p.add_argument("--cache-root", required=True); p.add_argument("--recipe", required=True); p.add_argument("--output", required=True)
    p = sub.add_parser("plan"); p.add_argument("--recipe", required=True)
    args = parser.parse_args()
    try:
        if args.command == "init": result = initialize(pathlib.Path(args.cache_root), args.limit_bytes)
        elif args.command == "status": result = status(pathlib.Path(args.cache_root))
        elif args.command == "preprocess": preprocess_worker(pathlib.Path(args.cache_root), args.limit_bytes, args.job_id, args.stage_bytes, args.dictionary_bytes, args.tick_seconds); return 0
        elif args.command == "build-validation": result = build_validation(pathlib.Path(args.cache_root), pathlib.Path(args.recipe), pathlib.Path(args.output))
        elif args.command == "verify": result = verify_validation(pathlib.Path(args.cache_root), pathlib.Path(args.recipe), pathlib.Path(args.output))
        elif args.command == "plan": result = plan(pathlib.Path(args.recipe))
        else: raise RuntimeError("unhandled command")
        print(json.dumps(result, indent=2, sort_keys=True)); return 0
    except CapacityError as exc: print(str(exc), file=sys.stderr); return 73
    except (OSError, ValueError, KeyError, RuntimeError, json.JSONDecodeError) as exc: print(f"FEATURE_CACHE_ERROR {exc}", file=sys.stderr); return 1


if __name__ == "__main__": raise SystemExit(main())
