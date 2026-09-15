#!/usr/bin/env python3
"""Bounded Python wheel cache with observable mirror staging and publication."""

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


def make_dir(path: pathlib.Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    os.chmod(path, DIR_MODE)


def atomic_json(path: pathlib.Path, value: dict) -> None:
    make_dir(path.parent)
    tmp = pathlib.Path(f"{path}.{os.getpid()}.{time.time_ns()}.tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.chmod(tmp, FILE_MODE)
    tmp.replace(path)
    os.chmod(path, FILE_MODE)


def read_json(path: pathlib.Path) -> dict:
    return json.loads(path.read_text())


def config_path(root: pathlib.Path) -> pathlib.Path:
    return root / ".state" / "config.json"


def progress_path(root: pathlib.Path) -> pathlib.Path:
    return root / ".state" / "mirror-progress.json"


def managed_files(root: pathlib.Path):
    for base in (root / "objects", root / ".incoming"):
        if not base.exists():
            continue
        yield from (path for path in base.rglob("*") if path.is_file())


def usage(root: pathlib.Path) -> dict:
    committed = sum(path.stat().st_size for path in (root / "objects").rglob("*") if path.is_file()) if (root / "objects").exists() else 0
    staging = sum(path.stat().st_size for path in (root / ".incoming").rglob("*") if path.is_file()) if (root / ".incoming").exists() else 0
    limit = int(read_json(config_path(root))["limit_bytes"])
    return {
        "cache_root": str(root),
        "limit_bytes": limit,
        "committed_bytes": committed,
        "staging_bytes": staging,
        "used_bytes": committed + staging,
        "free_bytes": max(0, limit - committed - staging),
        "committed_files": sum(1 for path in (root / "objects").rglob("*") if path.is_file()) if (root / "objects").exists() else 0,
        "staging_files": sum(1 for path in (root / ".incoming").rglob("*") if path.is_file()) if (root / ".incoming").exists() else 0,
    }


@contextlib.contextmanager
def locked(root: pathlib.Path):
    make_dir(root)
    lock = root / ".cache.lock"
    with lock.open("a+") as handle:
        os.chmod(lock, FILE_MODE)
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        yield
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def init(root: pathlib.Path, limit: int) -> dict:
    make_dir(root)
    make_dir(root / "objects")
    make_dir(root / ".incoming")
    make_dir(root / ".state")
    path = config_path(root)
    if path.exists():
        existing = int(read_json(path)["limit_bytes"])
        if existing != limit:
            raise RuntimeError(f"cache limit mismatch existing={existing} requested={limit}")
    else:
        atomic_json(path, {"schema_version": 1, "limit_bytes": limit, "scope": str(root)})
    return usage(root)


def deterministic_block(seed: str, counter: int, length: int = BLOCK) -> bytes:
    pattern = hashlib.sha256(f"{seed}:{counter}".encode()).digest()
    return (pattern * ((length + len(pattern) - 1) // len(pattern)))[:length]


def write_payload(path: pathlib.Path, seed: str, size: int) -> str:
    digest = hashlib.sha256()
    remaining = size
    counter = 0
    with path.open("r+b") as handle:
        handle.seek(0)
        while remaining:
            chunk = deterministic_block(seed, counter, min(BLOCK, remaining))
            handle.write(chunk)
            digest.update(chunk)
            remaining -= len(chunk)
            counter += 1
        handle.flush()
        os.fsync(handle.fileno())
    return digest.hexdigest()


def expected_digest(seed: str, size: int) -> str:
    digest = hashlib.sha256()
    remaining = size
    counter = 0
    while remaining:
        chunk = deterministic_block(seed, counter, min(BLOCK, remaining))
        digest.update(chunk)
        remaining -= len(chunk)
        counter += 1
    return digest.hexdigest()


def file_digest(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def reserve(root: pathlib.Path, path: pathlib.Path, size: int, operation: str) -> dict:
    with locked(root):
        current = usage(root)
        if current["used_bytes"] + size > current["limit_bytes"]:
            raise CapacityError(
                "WHEEL_CACHE_CAPACITY_EXCEEDED "
                f"scope={root} operation={operation} limit={current['limit_bytes']} "
                f"committed={current['committed_bytes']} staging={current['staging_bytes']} "
                f"required_staging={size}"
            )
        make_dir(path.parent)
        with path.open("wb") as handle:
            handle.truncate(size)
            if hasattr(os, "posix_fallocate"):
                os.posix_fallocate(handle.fileno(), 0, size)
        os.chmod(path, FILE_MODE)
        return usage(root)


def ensure_bootstrap(root: pathlib.Path, size: int, seed: str) -> dict:
    target = root / "objects" / "mirror" / "pip-bootstrap-2026.08.whl"
    if target.is_file():
        return {"path": str(target), "size": target.stat().st_size, "digest": file_digest(target), "created": False}
    stage = root / ".incoming" / "pip-bootstrap-2026.08.part"
    reserve(root, stage, size, "bootstrap_commit")
    digest = write_payload(stage, seed, size)
    make_dir(target.parent)
    stage.replace(target)
    os.chmod(target, FILE_MODE)
    return {"path": str(target), "size": size, "digest": digest, "created": True}


def sync_worker(root: pathlib.Path, limit: int, job_id: str, stage_bytes: int, bootstrap_bytes: int, tick: float) -> None:
    init(root, limit)
    bootstrap = ensure_bootstrap(root, bootstrap_bytes, "pip-bootstrap-cp312-manylinux")
    stage = root / ".incoming" / f"{job_id}.whl.part"
    if stage.exists():
        stage.unlink()
    reserve(root, stage, stage_bytes, "mirror_download")
    stop = False

    def request_stop(_signum, _frame):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    downloaded = 0
    chunk_count = 0
    started = time.time()
    try:
        with stage.open("r+b", buffering=0) as handle:
            while downloaded < stage_bytes and not stop:
                size = min(BLOCK, stage_bytes - downloaded)
                handle.seek(downloaded)
                handle.write(deterministic_block("numpy-cp312-nightly-wheel", chunk_count, size))
                downloaded += size
                chunk_count += 1
                atomic_json(progress_path(root), {
                    "job_id": job_id,
                    "phase": "download_and_verify",
                    "running": True,
                    "pid": os.getpid(),
                    "bytes_downloaded": downloaded,
                    "target_bytes": stage_bytes,
                    "staging_bytes": stage.stat().st_size,
                    "chunks_verified": chunk_count,
                    "commit_count": 1,
                    "bootstrap_digest": bootstrap["digest"],
                    "started_at": started,
                    "updated_at": time.time(),
                })
                time.sleep(tick)
        if not stop and downloaded == stage_bytes:
            digest = file_digest(stage)
            target = root / "objects" / "nightly" / f"{job_id}.whl"
            make_dir(target.parent)
            stage.replace(target)
            atomic_json(progress_path(root), {
                "job_id": job_id,
                "phase": "published",
                "running": True,
                "pid": os.getpid(),
                "bytes_downloaded": downloaded,
                "target_bytes": stage_bytes,
                "staging_bytes": 0,
                "chunks_verified": chunk_count,
                "commit_count": 2,
                "published_digest": digest,
                "updated_at": time.time(),
            })
            while not stop:
                time.sleep(1)
    finally:
        try:
            stage.unlink()
        except FileNotFoundError:
            pass
        atomic_json(progress_path(root), {
            "job_id": job_id,
            "phase": "stopped",
            "running": False,
            "pid": os.getpid(),
            "bytes_downloaded": downloaded,
            "target_bytes": stage_bytes,
            "staging_bytes": 0,
            "chunks_verified": chunk_count,
            "commit_count": 1,
            "updated_at": time.time(),
        })


def prefetch(root: pathlib.Path, recipe_path: pathlib.Path, output: pathlib.Path) -> dict:
    recipe = read_json(recipe_path)
    artifact_bytes = int(recipe["artifact_bytes"])
    seed = str(recipe["seed"])
    target = root / "objects" / "release" / str(recipe["artifact_name"])
    stage = root / ".incoming" / f"{recipe['artifact_name']}.part"
    if target.is_file() and target.stat().st_size == artifact_bytes and file_digest(target) == expected_digest(seed, artifact_bytes):
        digest = file_digest(target)
    else:
        try:
            stage.unlink()
        except FileNotFoundError:
            pass
        reserve(root, stage, artifact_bytes, "release_bundle_prefetch")
        digest = write_payload(stage, seed, artifact_bytes)
        if digest != expected_digest(seed, artifact_bytes):
            raise RuntimeError("release bundle digest mismatch before publication")
        make_dir(target.parent)
        stage.replace(target)
        os.chmod(target, FILE_MODE)
    result = {
        "schema_version": 1,
        "artifact": str(target.relative_to(root)),
        "artifact_bytes": artifact_bytes,
        "sha256": digest,
        "python": recipe["python"],
        "platform": recipe["platform"],
        "packages": recipe["packages"],
        "cache_scope": str(root),
        "verified": True,
    }
    atomic_json(output, result)
    return result


def verify(root: pathlib.Path, recipe_path: pathlib.Path, output: pathlib.Path) -> dict:
    recipe = read_json(recipe_path)
    attestation = read_json(output)
    target = root / "objects" / "release" / str(recipe["artifact_name"])
    expected = expected_digest(str(recipe["seed"]), int(recipe["artifact_bytes"]))
    actual = file_digest(target)
    if target.stat().st_size != int(recipe["artifact_bytes"]):
        raise RuntimeError("release bundle size mismatch")
    if actual != expected or attestation.get("sha256") != expected:
        raise RuntimeError("release bundle digest or attestation mismatch")
    if attestation.get("packages") != recipe["packages"] or attestation.get("verified") is not True:
        raise RuntimeError("release package lock mismatch")
    return {"verified": True, "artifact": str(target), "sha256": actual, "status": usage(root)}


def plan(recipe_path: pathlib.Path) -> dict:
    recipe = read_json(recipe_path)
    return {
        "artifact_name": recipe["artifact_name"],
        "peak_staging_bytes": int(recipe["artifact_bytes"]),
        "committed_bytes": int(recipe["artifact_bytes"]),
        "sha256": expected_digest(str(recipe["seed"]), int(recipe["artifact_bytes"])),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("init")
    p.add_argument("--cache-root", required=True)
    p.add_argument("--limit-bytes", required=True, type=int)
    p = sub.add_parser("status")
    p.add_argument("--cache-root", required=True)
    p = sub.add_parser("mirror-sync")
    p.add_argument("--cache-root", required=True)
    p.add_argument("--limit-bytes", required=True, type=int)
    p.add_argument("--job-id", required=True)
    p.add_argument("--stage-bytes", required=True, type=int)
    p.add_argument("--bootstrap-bytes", required=True, type=int)
    p.add_argument("--tick-seconds", required=True, type=float)
    p = sub.add_parser("prefetch")
    p.add_argument("--cache-root", required=True)
    p.add_argument("--recipe", required=True)
    p.add_argument("--output", required=True)
    p = sub.add_parser("verify")
    p.add_argument("--cache-root", required=True)
    p.add_argument("--recipe", required=True)
    p.add_argument("--output", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--recipe", required=True)
    args = parser.parse_args()
    try:
        if args.command == "init":
            result = init(pathlib.Path(args.cache_root), args.limit_bytes)
        elif args.command == "status":
            result = usage(pathlib.Path(args.cache_root))
        elif args.command == "mirror-sync":
            sync_worker(pathlib.Path(args.cache_root), args.limit_bytes, args.job_id, args.stage_bytes, args.bootstrap_bytes, args.tick_seconds)
            return 0
        elif args.command == "prefetch":
            result = prefetch(pathlib.Path(args.cache_root), pathlib.Path(args.recipe), pathlib.Path(args.output))
        elif args.command == "verify":
            result = verify(pathlib.Path(args.cache_root), pathlib.Path(args.recipe), pathlib.Path(args.output))
        elif args.command == "plan":
            result = plan(pathlib.Path(args.recipe))
        else:
            raise RuntimeError("unhandled command")
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0
    except CapacityError as exc:
        print(str(exc), file=sys.stderr)
        return 73
    except (OSError, ValueError, KeyError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"WHEEL_CACHE_ERROR {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
