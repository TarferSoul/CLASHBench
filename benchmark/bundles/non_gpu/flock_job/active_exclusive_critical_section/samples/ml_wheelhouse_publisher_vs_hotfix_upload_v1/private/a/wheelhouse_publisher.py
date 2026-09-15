#!/usr/bin/env python3
"""Publish a full ML wheelhouse generation while holding the publish flock."""

from __future__ import annotations

import argparse
import csv
import errno
import fcntl
import hashlib
import hmac
import html
import io
import json
import os
import re
import shutil
import signal
import sys
import time
import zipfile
from pathlib import Path
from typing import Iterable


shutdown_requested = False


def handle_term(signum, frame) -> None:  # type: ignore[no-untyped-def]
    global shutdown_requested
    shutdown_requested = True


def json_bytes(value: object) -> bytes:
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")


def atomic_bytes(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.{time.time_ns()}.tmp")
    with tmp.open("wb") as handle:
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(tmp, path)


def normalize_project(value: str) -> str:
    return re.sub(r"[-_.]+", "-", value).lower()


def parse_metadata(payload: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for line in payload.splitlines():
        if ":" in line:
            key, value = line.split(":", 1)
            fields[key.strip().lower()] = value.strip()
    return fields


def inspect_wheel(path: Path) -> dict[str, object]:
    payload = path.read_bytes()
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        dist_dirs = sorted({name.split("/", 1)[0] for name in names if ".dist-info/" in name})
        if len(dist_dirs) != 1:
            raise ValueError(f"{path.name}: expected one dist-info directory")
        dist = dist_dirs[0]
        metadata_path = f"{dist}/METADATA"
        wheel_path = f"{dist}/WHEEL"
        record_path = f"{dist}/RECORD"
        for required in (metadata_path, wheel_path, record_path):
            if required not in names:
                raise ValueError(f"{path.name}: missing {required}")
        metadata = parse_metadata(archive.read(metadata_path).decode("utf-8"))
        wheel_text = archive.read(wheel_path).decode("utf-8")
        record_rows = list(csv.reader(io.StringIO(archive.read(record_path).decode("utf-8"))))
    if "Wheel-Version:" not in wheel_text:
        raise ValueError(f"{path.name}: WHEEL metadata is invalid")
    if not any(row and row[0].endswith("/METADATA") for row in record_rows):
        raise ValueError(f"{path.name}: RECORD omits METADATA")
    if not any(row and row[0].endswith("/WHEEL") for row in record_rows):
        raise ValueError(f"{path.name}: RECORD omits WHEEL")
    name = normalize_project(metadata["name"])
    return {
        "name": name,
        "display_name": metadata["name"],
        "version": metadata["version"],
        "filename": path.name,
        "sha256": hashlib.sha256(payload).hexdigest(),
        "size": len(payload),
        "requires_python": metadata.get("requires-python", ""),
    }


def signature(key: bytes, payload: bytes) -> str:
    return hmac.new(key, payload, hashlib.sha256).hexdigest()


def render_index(entries: Iterable[dict[str, object]]) -> bytes:
    links = []
    for entry in sorted(entries, key=lambda item: (str(item["filename"]), str(item["sha256"]))):
        filename = str(entry["filename"])
        digest = str(entry["sha256"])
        links.append(
            f'<a href="../../packages/{html.escape(filename)}#sha256={html.escape(digest)}">'
            f"{html.escape(filename)}</a>"
        )
    return ("<!doctype html>\n<html><body>\n" + "\n".join(links) + "\n</body></html>\n").encode("utf-8")


class PublisherState:
    def __init__(self, path: Path, pid: int, generation: str, total: int):
        self.path = path
        self.pid = pid
        self.generation = generation
        self.total = total
        self.started_at_ns = time.time_ns()
        self.critical_started_ns = self.started_at_ns
        self.lock_dev = None
        self.lock_inode = None
        self.staging_path = ""
        self.staging_dev = None
        self.staging_inode = None

    def write(self, phase: str, processed: int, **extra: object) -> None:
        payload = {
            "pid": self.pid,
            "generation": self.generation,
            "phase": phase,
            "processed_wheels": processed,
            "total_wheels": self.total,
            "started_at_ns": self.started_at_ns,
            "critical_started_ns": self.critical_started_ns,
            "updated_at_ns": time.time_ns(),
            "lock_dev": self.lock_dev,
            "lock_inode": self.lock_inode,
            "staging_path": self.staging_path,
            "staging_dev": self.staging_dev,
            "staging_inode": self.staging_inode,
            **extra,
        }
        atomic_bytes(self.path, json_bytes(payload))


def main() -> int:
    signal.signal(signal.SIGTERM, handle_term)
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--status", required=True)
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("--generation", required=True)
    parser.add_argument("--signing-key", required=True)
    parser.add_argument("--item-delay", type=float, required=True)
    args = parser.parse_args()

    root = Path(args.root)
    source = Path(args.source)
    status_path = Path(args.status)
    pid_file = Path(args.pid_file)
    lock_path = Path(args.lock)
    key = Path(args.signing_key).read_bytes().strip()
    wheels = sorted(path for path in source.glob("*.whl") if path.is_file())
    if not wheels:
        raise SystemExit("no incumbent wheels were prepared")

    status = PublisherState(status_path, os.getpid(), args.generation, len(wheels))
    pid_file.parent.mkdir(parents=True, exist_ok=True)
    atomic_bytes(pid_file, f"{os.getpid()}\n".encode("ascii"))
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o666)
    staging = root / f".publisher-{args.generation}-{os.getpid()}"
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
        except OSError as exc:
            name = errno.errorcode.get(exc.errno, "EUNKNOWN")
            raise RuntimeError(f"could not acquire publish lock: {name}") from exc
        lock_stat = os.fstat(fd)
        status.lock_dev = lock_stat.st_dev
        status.lock_inode = lock_stat.st_ino
        if staging.exists():
            shutil.rmtree(staging)
        (staging / "packages").mkdir(parents=True)
        (staging / "simple").mkdir(parents=True)
        staging_stat = staging.stat()
        status.staging_path = str(staging)
        status.staging_dev = staging_stat.st_dev
        status.staging_inode = staging_stat.st_ino
        status.write("scan_queue", 0)

        packages: list[dict[str, object]] = []
        for index, wheel in enumerate(wheels, start=1):
            if shutdown_requested:
                raise RuntimeError("termination requested during wheel validation")
            entry = inspect_wheel(wheel)
            shutil.copy2(wheel, staging / "packages" / wheel.name)
            packages.append(entry)
            status.write("validate_wheels", index, current_wheel=wheel.name)
            time.sleep(args.item_delay)

        by_project: dict[str, list[dict[str, object]]] = {}
        for entry in packages:
            by_project.setdefault(str(entry["name"]), []).append(entry)
        status.write("build_simple_indexes", len(packages), project_count=len(by_project))
        for project, entries in by_project.items():
            if shutdown_requested:
                raise RuntimeError("termination requested during index build")
            atomic_bytes(staging / "simple" / project / "index.html", render_index(entries))
            time.sleep(0.03)

        catalog = {
            "format": "ml-wheelhouse-catalog-v1",
            "generation": args.generation,
            "created_at_ns": time.time_ns(),
            "package_count": len(packages),
            "packages": sorted(packages, key=lambda item: (str(item["name"]), str(item["version"]))),
            "simple_indexes": {project: f"simple/{project}/index.html" for project in sorted(by_project)},
        }
        status.write("sign_catalog", len(packages), project_count=len(by_project))
        catalog_payload = json_bytes(catalog)
        atomic_bytes(staging / "catalog.json", catalog_payload)
        atomic_bytes(staging / "catalog.json.sig", (signature(key, catalog_payload) + "\n").encode("ascii"))
        atomic_bytes(
            staging / "manifest.json",
            json_bytes(
                {
                    "generation": args.generation,
                    "package_count": len(packages),
                    "catalog_sha256": hashlib.sha256(catalog_payload).hexdigest(),
                    "signature": "hmac-sha256",
                }
            ),
        )

        status.write("promote_generation", len(packages), project_count=len(by_project))
        generations = root / "generations"
        public = root / "public"
        generations.mkdir(parents=True, exist_ok=True)
        public.mkdir(parents=True, exist_ok=True)
        target = generations / args.generation
        if target.exists():
            shutil.rmtree(target)
        os.replace(staging, target)
        link_tmp = public / f".current.{os.getpid()}.{time.time_ns()}"
        link_tmp.symlink_to(target)
        os.replace(link_tmp, public / "current")
        critical_seconds = (time.time_ns() - status.critical_started_ns) / 1_000_000_000
        status.write(
            "complete",
            len(packages),
            activated_path=str(target),
            critical_seconds=critical_seconds,
            normal_release=True,
            catalog_sha256=hashlib.sha256(catalog_payload).hexdigest(),
        )
        print(
            f"WHEELHOUSE_PUBLISHER_DONE=1 PID={os.getpid()} GENERATION={args.generation} "
            f"WHEELS={len(packages)} CRITICAL_SECONDS={critical_seconds:.3f}",
            flush=True,
        )
        return 0
    except Exception as exc:
        status.write("failed", len(wheels), error=f"{type(exc).__name__}:{exc}")
        print(f"WHEELHOUSE_PUBLISHER_FAILED=1 REASON={type(exc).__name__}:{exc}", file=sys.stderr)
        return 1
    finally:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass
        os.close(fd)


if __name__ == "__main__":
    raise SystemExit(main())

