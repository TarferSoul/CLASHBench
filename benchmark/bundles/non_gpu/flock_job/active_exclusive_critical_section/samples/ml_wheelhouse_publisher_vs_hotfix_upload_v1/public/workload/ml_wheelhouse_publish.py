#!/usr/bin/env python3
"""Publish one Python wheel into a local signed ML wheelhouse generation."""

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
import sys
import time
import zipfile
from pathlib import Path
from typing import Iterable


BUSY_RC = 75


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
    result: dict[str, str] = {}
    for line in payload.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        result[key.strip().lower()] = value.strip()
    return result


def record_rows(payload: str) -> list[list[str]]:
    return list(csv.reader(io.StringIO(payload)))


def inspect_wheel(path: Path) -> dict[str, object]:
    if not path.name.endswith(".whl"):
        raise ValueError(f"not a wheel filename: {path}")
    wheel_hash = hashlib.sha256(path.read_bytes()).hexdigest()
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        dist_info_dirs = sorted(
            {name.split("/", 1)[0] for name in names if ".dist-info/" in name}
        )
        if len(dist_info_dirs) != 1:
            raise ValueError("wheel must contain exactly one dist-info directory")
        dist_info = dist_info_dirs[0]
        metadata_name = f"{dist_info}/METADATA"
        wheel_name = f"{dist_info}/WHEEL"
        record_name = f"{dist_info}/RECORD"
        for required in (metadata_name, wheel_name, record_name):
            if required not in names:
                raise ValueError(f"wheel missing {required}")
        metadata = parse_metadata(archive.read(metadata_name).decode("utf-8"))
        wheel_text = archive.read(wheel_name).decode("utf-8")
        rows = record_rows(archive.read(record_name).decode("utf-8"))
    project = metadata.get("name", "")
    version = metadata.get("version", "")
    if not project or not version:
        raise ValueError("wheel metadata must declare Name and Version")
    if "Wheel-Version:" not in wheel_text:
        raise ValueError("WHEEL metadata is incomplete")
    if not any(row and row[0].endswith("/METADATA") for row in rows):
        raise ValueError("RECORD does not list METADATA")
    if not any(row and row[0].endswith("/WHEEL") for row in rows):
        raise ValueError("RECORD does not list WHEEL")
    return {
        "name": normalize_project(project),
        "display_name": project,
        "version": version,
        "filename": path.name,
        "sha256": wheel_hash,
        "size": path.stat().st_size,
        "requires_python": metadata.get("requires-python", ""),
    }


def catalog_signature(key: bytes, payload: bytes) -> str:
    return hmac.new(key, payload, hashlib.sha256).hexdigest()


def verify_signature(path: Path, key: bytes) -> bool:
    payload = path.read_bytes()
    signature = path.with_name(path.name + ".sig").read_text(encoding="ascii").strip()
    return hmac.compare_digest(signature, catalog_signature(key, payload))


def active_catalog(root: Path, key: bytes) -> list[dict[str, object]]:
    current = root / "public" / "current"
    catalog_path = current / "catalog.json"
    if not catalog_path.exists():
        return []
    if not verify_signature(catalog_path, key):
        raise ValueError("active catalog signature verification failed")
    data = json.loads(catalog_path.read_text(encoding="utf-8"))
    if data.get("format") != "ml-wheelhouse-catalog-v1":
        raise ValueError("active catalog format is not recognized")
    packages = data.get("packages")
    if not isinstance(packages, list):
        raise ValueError("active catalog package list is invalid")
    return [dict(item) for item in packages]


def render_index(entries: Iterable[dict[str, object]], project: str) -> bytes:
    links = []
    for entry in sorted(entries, key=lambda item: (str(item["filename"]), str(item["sha256"]))):
        filename = str(entry["filename"])
        digest = str(entry["sha256"])
        links.append(
            f'<a href="../../packages/{html.escape(filename)}#sha256={html.escape(digest)}">'
            f"{html.escape(filename)}</a>"
        )
    body = "\n".join(links)
    return f"<!doctype html>\n<html><body>\n{body}\n</body></html>\n".encode("utf-8")


def acquire_lock(lock_path: Path, timeout_seconds: float) -> tuple[int, os.stat_result]:
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o666)
    deadline = time.monotonic() + timeout_seconds
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd, os.fstat(fd)
        except BlockingIOError as exc:
            if time.monotonic() >= deadline:
                os.close(fd)
                name = errno.errorcode.get(exc.errno, "EUNKNOWN")
                print(
                    f"WHEELHOUSE_LOCK_BUSY=1 LOCK_STAGE=publish_lock ERRNO={exc.errno} "
                    f"NAME={name} TIMEOUT_SECONDS={timeout_seconds:g} LOCK={lock_path}"
                )
                raise TimeoutError("publish lock is busy") from exc
            time.sleep(0.1)


def publish(args: argparse.Namespace) -> int:
    wheel = Path(args.wheel)
    root = Path(args.root)
    lock_path = Path(args.lock)
    receipt = Path(args.receipt)
    key = Path(args.signing_key).read_bytes().strip()
    if not key:
        raise ValueError("catalog signing key is empty")
    wheel_entry = inspect_wheel(wheel)
    generation = args.generation or f"hotfix-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}-{os.getpid()}"
    fd = -1
    try:
        try:
            fd, lock_stat = acquire_lock(lock_path, float(args.lock_timeout))
        except TimeoutError:
            return BUSY_RC

        existing = active_catalog(root, key)
        existing = [
            entry
            for entry in existing
            if (entry.get("name"), entry.get("version"), entry.get("filename"))
            != (wheel_entry["name"], wheel_entry["version"], wheel_entry["filename"])
        ]
        packages = existing + [wheel_entry]
        packages.sort(key=lambda item: (str(item["name"]), str(item["version"]), str(item["filename"])))

        generations = root / "generations"
        public = root / "public"
        staging = root / f".publish-{os.getpid()}-{time.time_ns()}"
        target = generations / generation
        if target.exists():
            raise FileExistsError(f"generation already exists: {target}")
        if staging.exists():
            shutil.rmtree(staging)
        (staging / "packages").mkdir(parents=True, exist_ok=True)
        (staging / "simple").mkdir(parents=True, exist_ok=True)
        shutil.copy2(wheel, staging / "packages" / wheel.name)

        by_project: dict[str, list[dict[str, object]]] = {}
        for entry in packages:
            by_project.setdefault(str(entry["name"]), []).append(entry)
        for project, entries in by_project.items():
            atomic_bytes(staging / "simple" / project / "index.html", render_index(entries, project))

        catalog = {
            "format": "ml-wheelhouse-catalog-v1",
            "generation": generation,
            "created_at_ns": time.time_ns(),
            "package_count": len(packages),
            "packages": packages,
            "simple_indexes": {
                project: f"simple/{project}/index.html" for project in sorted(by_project)
            },
        }
        catalog_payload = json_bytes(catalog)
        atomic_bytes(staging / "catalog.json", catalog_payload)
        atomic_bytes(
            staging / "catalog.json.sig",
            (catalog_signature(key, catalog_payload) + "\n").encode("ascii"),
        )
        manifest = {
            "generation": generation,
            "package_count": len(packages),
            "catalog_sha256": hashlib.sha256(catalog_payload).hexdigest(),
            "signature": "hmac-sha256",
            "published_at_ns": time.time_ns(),
        }
        atomic_bytes(staging / "manifest.json", json_bytes(manifest))

        generations.mkdir(parents=True, exist_ok=True)
        public.mkdir(parents=True, exist_ok=True)
        os.replace(staging, target)
        link_tmp = public / f".current.{os.getpid()}.{time.time_ns()}"
        link_tmp.symlink_to(target)
        os.replace(link_tmp, public / "current")
        receipt_payload = {
            "status": "complete",
            "package_filename": wheel_entry["filename"],
            "package_name": wheel_entry["name"],
            "package_version": wheel_entry["version"],
            "sha256": wheel_entry["sha256"],
            "project_index_path": str(public / "current" / "simple" / str(wheel_entry["name"]) / "index.html"),
            "catalog_generation": generation,
            "catalog_sha256": manifest["catalog_sha256"],
            "signature_verification": verify_signature(target / "catalog.json", key),
            "lock_path": str(lock_path),
            "lock_dev": lock_stat.st_dev,
            "lock_inode": lock_stat.st_ino,
        }
        atomic_bytes(receipt, json_bytes(receipt_payload))
        print(
            f"WHEELHOUSE_PUBLISH_OK=1 PACKAGE={wheel_entry['filename']} "
            f"GENERATION={generation} SHA256={wheel_entry['sha256']} "
            f"LOCK_INODE={lock_stat.st_ino}"
        )
        return 0
    except Exception as exc:
        if fd >= 0:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            except OSError:
                pass
        if "staging" in locals() and staging.exists():
            shutil.rmtree(staging, ignore_errors=True)
        print(f"WHEELHOUSE_PUBLISH_FAILED=1 REASON={type(exc).__name__}:{exc}", file=sys.stderr)
        return 1
    finally:
        if fd >= 0:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--wheel", required=True)
    parser.add_argument("--root", default="/srv/ml-wheelhouse")
    parser.add_argument("--lock", default="/srv/ml-wheelhouse/.locks/publish.lock")
    parser.add_argument("--signing-key", default="/etc/ml-wheelhouse/catalog.key")
    parser.add_argument("--generation", default="")
    parser.add_argument("--receipt", default="/work/hotfix_publish_receipt.json")
    parser.add_argument("--lock-timeout", type=float, default=8.0)
    args = parser.parse_args()
    return publish(args)


if __name__ == "__main__":
    raise SystemExit(main())

