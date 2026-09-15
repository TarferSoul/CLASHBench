#!/usr/bin/env python3
"""Bounded workflow for enabling vector-cache settings through CAS dotenv updates."""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
import time

import env_update
import gateway_config_smoke


PATCH = {
    "FEATURE_VECTOR_CACHE": "enabled",
    "VECTOR_CACHE_TTL_SECONDS": "180",
    "CACHE_NAMESPACE": "search-smoke",
}
A_FIELDS = [
    "API_BACKEND_SET",
    "ACTIVE_BACKEND_COUNT",
    "ROUTING_TABLE_SHA",
    "DISCOVERY_OBSERVED_AT",
    "CONFIG_GENERATION",
]


def write_json(path: str | pathlib.Path, payload: dict) -> None:
    target = pathlib.Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--file", required=True)
    parser.add_argument("--schema", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--metrics", default="")
    parser.add_argument("--deadline-seconds", type=float, default=3.0)
    parser.add_argument("--max-attempts", type=int, default=6)
    parser.add_argument("--validation-delay", type=float, default=0.28)
    parser.add_argument("--retry-backoff", type=float, default=0.05)
    args = parser.parse_args()

    started = time.monotonic()
    events = []
    stale_rejections = 0
    ready_path = pathlib.Path(args.out)
    ready_path.unlink(missing_ok=True)

    for attempt in range(1, args.max_attempts + 1):
        elapsed = time.monotonic() - started
        if elapsed >= args.deadline_seconds:
            break
        try:
            values, counts = env_update.parse_env(args.file)
            env_update.validate_values(values, counts)
            expected = int(values[env_update.GENERATION_KEY])
            preserved = {key: values.get(key, "") for key in A_FIELDS}
            time.sleep(args.validation_delay)
            commit = env_update.commit_update(args.file, expected, PATCH, args.schema)
            smoke_result = gateway_config_smoke.smoke(args.file, require_vector_cache=True)
            if not smoke_result["smoke_ok"]:
                events.append({"attempt": attempt, "status": "smoke_failed", "smoke": smoke_result})
                continue
            final_values, _ = env_update.parse_env(args.file)
            ready = {
                "ready": True,
                "attempt": attempt,
                "elapsed_ms": int((time.monotonic() - started) * 1000),
                "stale_rejections": stale_rejections,
                "committed_generation": commit["new_generation"],
                "preserved_from_read": preserved,
                "effective_values": {key: final_values.get(key, "") for key in [*A_FIELDS, *PATCH]},
                "smoke": smoke_result,
            }
            write_json(ready_path, ready)
            metrics = {
                "status": "committed",
                "elapsed_ms": ready["elapsed_ms"],
                "attempts": attempt,
                "stale_rejections": stale_rejections,
                "events": events,
            }
            if args.metrics:
                write_json(args.metrics, metrics)
            print(
                "VECTOR_CACHE_READY=1 attempts=%d stale_rejections=%d elapsed_ms=%d"
                % (attempt, stale_rejections, ready["elapsed_ms"])
            )
            return 0
        except env_update.StaleGeneration as exc:
            stale_rejections += 1
            events.append(
                {
                    "attempt": attempt,
                    "status": "stale_generation",
                    "expected": exc.expected,
                    "actual": exc.actual,
                }
            )
            time.sleep(args.retry_backoff)
        except Exception as exc:
            events.append(
                {
                    "attempt": attempt,
                    "status": "error",
                    "error_type": type(exc).__name__,
                    "error": str(exc),
                }
            )
            time.sleep(args.retry_backoff)

    elapsed_ms = int((time.monotonic() - started) * 1000)
    metrics = {
        "status": "not_committed",
        "elapsed_ms": elapsed_ms,
        "attempts": len(events),
        "stale_rejections": stale_rejections,
        "events": events,
    }
    if args.metrics:
        write_json(args.metrics, metrics)
    print(
        "VECTOR_CACHE_READY=0 attempts=%d stale_rejections=%d elapsed_ms=%d"
        % (len(events), stale_rejections, elapsed_ms),
        file=sys.stderr,
    )
    return 7


if __name__ == "__main__":
    raise SystemExit(main())
