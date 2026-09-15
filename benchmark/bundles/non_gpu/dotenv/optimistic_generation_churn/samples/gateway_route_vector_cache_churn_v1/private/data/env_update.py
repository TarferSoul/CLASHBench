#!/usr/bin/env python3
"""Generation-aware dotenv update tool for the gateway fixture."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import pathlib
import re
import sys
import tempfile
from typing import Dict, Iterable, Tuple


GENERATION_KEY = "CONFIG_GENERATION"
ROUTE_FIELDS = (
    "API_BACKEND_SET",
    "ACTIVE_BACKEND_COUNT",
    "ROUTING_TABLE_SHA",
    "DISCOVERY_OBSERVED_AT",
)
DISPLAY_ORDER = (
    "APP_ENV",
    "GATEWAY_NAME",
    "API_BACKEND_SET",
    "ACTIVE_BACKEND_COUNT",
    "ROUTING_TABLE_SHA",
    "DISCOVERY_OBSERVED_AT",
    GENERATION_KEY,
    "FEATURE_VECTOR_CACHE",
    "VECTOR_CACHE_TTL_SECONDS",
    "CACHE_NAMESPACE",
)


class EnvError(RuntimeError):
    pass


class StaleGeneration(EnvError):
    def __init__(self, expected: int, actual: int):
        super().__init__(f"stale generation: expected {expected}, actual {actual}")
        self.expected = expected
        self.actual = actual


def parse_env(path: os.PathLike[str] | str) -> Tuple[Dict[str, str], Dict[str, int]]:
    values: Dict[str, str] = {}
    counts: Dict[str, int] = {}
    for line in pathlib.Path(path).read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "=" not in line:
            raise EnvError(f"invalid dotenv line without assignment: {line!r}")
        key, raw = line.split("=", 1)
        key = key.strip()
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
            raise EnvError(f"invalid dotenv key: {key!r}")
        value = raw.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
            value = value[1:-1]
        values[key] = value
        counts[key] = counts.get(key, 0) + 1
    return values, counts


def quote_value(value: str) -> str:
    if re.fullmatch(r"[A-Za-z0-9_./:@=;,+-]+", value):
        return value
    return json.dumps(value, ensure_ascii=False)


def render_env(values: Dict[str, str]) -> str:
    emitted = []
    seen = set()
    for key in DISPLAY_ORDER:
        if key in values:
            emitted.append(f"{key}={quote_value(str(values[key]))}")
            seen.add(key)
    for key in sorted(set(values) - seen):
        emitted.append(f"{key}={quote_value(str(values[key]))}")
    return "\n".join(emitted) + "\n"


def route_sha(values: Dict[str, str]) -> str:
    material = "|".join(
        [
            values.get("API_BACKEND_SET", ""),
            values.get("ACTIVE_BACKEND_COUNT", ""),
            values.get("DISCOVERY_OBSERVED_AT", ""),
        ]
    )
    return hashlib.sha256(material.encode("utf-8")).hexdigest()[:16]


def backend_entries(values: Dict[str, str]) -> Iterable[str]:
    raw = values.get("API_BACKEND_SET", "")
    return [item for item in raw.split(";") if item]


def validate_values(values: Dict[str, str], counts: Dict[str, int] | None = None) -> None:
    counts = counts or {}
    required = [
        "APP_ENV",
        "GATEWAY_NAME",
        "API_BACKEND_SET",
        "ACTIVE_BACKEND_COUNT",
        "ROUTING_TABLE_SHA",
        "DISCOVERY_OBSERVED_AT",
        GENERATION_KEY,
    ]
    missing = [key for key in required if key not in values]
    if missing:
        raise EnvError(f"missing required keys: {','.join(missing)}")
    duplicates = [key for key, count in counts.items() if count > 1]
    if duplicates:
        raise EnvError(f"duplicate dotenv assignments: {','.join(sorted(duplicates))}")
    try:
        generation = int(values[GENERATION_KEY])
    except ValueError as exc:
        raise EnvError("CONFIG_GENERATION must be an integer") from exc
    if generation < 0:
        raise EnvError("CONFIG_GENERATION must be non-negative")
    entries = list(backend_entries(values))
    active = [entry for entry in entries if ":s=up" in entry]
    try:
        active_count = int(values["ACTIVE_BACKEND_COUNT"])
    except ValueError as exc:
        raise EnvError("ACTIVE_BACKEND_COUNT must be an integer") from exc
    if active_count != len(active):
        raise EnvError(
            f"ACTIVE_BACKEND_COUNT={active_count} does not match active routes={len(active)}"
        )
    for entry in entries:
        if not re.fullmatch(
            r"[a-z0-9-]+@127\.0\.0\.1:\d+:w=\d+:s=(?:up|draining)",
            entry,
        ):
            raise EnvError(f"invalid backend route entry: {entry!r}")
    expected_sha = route_sha(values)
    if values["ROUTING_TABLE_SHA"] != expected_sha:
        raise EnvError(
            f"ROUTING_TABLE_SHA={values['ROUTING_TABLE_SHA']} expected={expected_sha}"
        )
    if "FEATURE_VECTOR_CACHE" in values and values["FEATURE_VECTOR_CACHE"] not in {
        "disabled",
        "enabled",
    }:
        raise EnvError("FEATURE_VECTOR_CACHE must be disabled or enabled")
    if "VECTOR_CACHE_TTL_SECONDS" in values:
        try:
            ttl = int(values["VECTOR_CACHE_TTL_SECONDS"])
        except ValueError as exc:
            raise EnvError("VECTOR_CACHE_TTL_SECONDS must be an integer") from exc
        if ttl < 30 or ttl > 3600:
            raise EnvError("VECTOR_CACHE_TTL_SECONDS outside allowed range")
    if "CACHE_NAMESPACE" in values and not re.fullmatch(
        r"[a-z0-9][a-z0-9-]{2,40}", values["CACHE_NAMESPACE"]
    ):
        raise EnvError("CACHE_NAMESPACE must be a short slug")


def atomic_write(path: pathlib.Path, values: Dict[str, str]) -> None:
    stat = path.stat()
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(render_env(values))
            handle.flush()
            os.fsync(handle.fileno())
        os.chown(tmp_name, stat.st_uid, stat.st_gid)
        os.chmod(tmp_name, stat.st_mode & 0o777)
        os.replace(tmp_name, path)
        dir_fd = os.open(path.parent, os.O_DIRECTORY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass


def commit_update(
    path: os.PathLike[str] | str,
    expect_generation: int,
    patch: Dict[str, str],
    schema_path: os.PathLike[str] | str | None = None,
) -> Dict[str, int]:
    del schema_path
    env_path = pathlib.Path(path)
    lock_path = env_path.with_suffix(env_path.suffix + ".caslock")
    lock_path.touch(exist_ok=True)
    with lock_path.open("r+") as lock_handle:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
        current, counts = parse_env(env_path)
        validate_values(current, counts)
        actual = int(current[GENERATION_KEY])
        if actual != int(expect_generation):
            raise StaleGeneration(int(expect_generation), actual)
        merged = dict(current)
        for key, value in patch.items():
            if key == GENERATION_KEY:
                continue
            if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
                raise EnvError(f"invalid patch key: {key!r}")
            merged[key] = str(value)
        merged[GENERATION_KEY] = str(actual + 1)
        validate_values(merged, {})
        atomic_write(env_path, merged)
        return {"old_generation": actual, "new_generation": actual + 1}


def main() -> int:
    parser = argparse.ArgumentParser(description="Read or CAS-update a dotenv file.")
    parser.add_argument("--file", required=True)
    parser.add_argument("--schema", default="")
    parser.add_argument("--read-json", action="store_true")
    parser.add_argument("--validate", action="store_true")
    parser.add_argument("--expect-generation", type=int)
    parser.add_argument("--merge-json", default="")
    parser.add_argument("--atomic", action="store_true")
    args = parser.parse_args()

    try:
        if args.read_json:
            values, counts = parse_env(args.file)
            validate_values(values, counts)
            print(json.dumps({"values": values, "counts": counts}, indent=2, sort_keys=True))
            return 0
        if args.validate:
            values, counts = parse_env(args.file)
            validate_values(values, counts)
            print(
                "DOTENV_OK=1 generation=%s active_backends=%s route_sha=%s"
                % (
                    values[GENERATION_KEY],
                    values["ACTIVE_BACKEND_COUNT"],
                    values["ROUTING_TABLE_SHA"],
                )
            )
            return 0
        if args.expect_generation is None or not args.merge_json:
            raise EnvError("commit mode requires --expect-generation and --merge-json")
        patch = json.loads(args.merge_json)
        if not isinstance(patch, dict):
            raise EnvError("--merge-json must decode to an object")
        result = commit_update(args.file, args.expect_generation, patch, args.schema or None)
        print(json.dumps({"status": "committed", **result}, sort_keys=True))
        return 0
    except StaleGeneration as exc:
        print(
            json.dumps(
                {
                    "status": "stale_generation",
                    "expected": exc.expected,
                    "actual": exc.actual,
                },
                sort_keys=True,
            )
        )
        return 11
    except Exception as exc:
        print(f"DOTENV_ERROR={type(exc).__name__}: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
