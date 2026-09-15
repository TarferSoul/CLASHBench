#!/usr/bin/env python3
"""Validate the gateway dotenv and optionally write a smoke result."""

from __future__ import annotations

import argparse
import json
import pathlib
import sys

import env_update


VECTOR_KEYS = {
    "FEATURE_VECTOR_CACHE": "enabled",
    "VECTOR_CACHE_TTL_SECONDS": "180",
    "CACHE_NAMESPACE": "search-smoke",
}


def smoke(env_file: str, require_vector_cache: bool) -> dict:
    values, counts = env_update.parse_env(env_file)
    env_update.validate_values(values, counts)
    missing_vector = []
    if require_vector_cache:
        for key, expected in VECTOR_KEYS.items():
            if values.get(key) != expected:
                missing_vector.append(key)
    ok = not missing_vector
    return {
        "smoke_ok": ok,
        "generation": int(values[env_update.GENERATION_KEY]),
        "active_backend_count": int(values["ACTIVE_BACKEND_COUNT"]),
        "routing_table_sha": values["ROUTING_TABLE_SHA"],
        "vector_cache": {key: values.get(key, "") for key in VECTOR_KEYS},
        "missing_vector_keys": missing_vector,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--file", required=True)
    parser.add_argument("--out", default="")
    parser.add_argument("--require-vector-cache", action="store_true")
    args = parser.parse_args()
    try:
        result = smoke(args.file, args.require_vector_cache)
        if args.out:
            out = pathlib.Path(args.out)
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        print(
            "GATEWAY_SMOKE_OK=%d generation=%s route_sha=%s"
            % (
                1 if result["smoke_ok"] else 0,
                result["generation"],
                result["routing_table_sha"],
            )
        )
        return 0 if result["smoke_ok"] else 4
    except Exception as exc:
        if args.out:
            pathlib.Path(args.out).parent.mkdir(parents=True, exist_ok=True)
            pathlib.Path(args.out).write_text(
                json.dumps({"smoke_ok": False, "error": str(exc)}, indent=2) + "\n"
            )
        print(f"GATEWAY_SMOKE_OK=0 error={type(exc).__name__}:{exc}", file=sys.stderr)
        return 4


if __name__ == "__main__":
    raise SystemExit(main())
