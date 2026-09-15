#!/usr/bin/env python3
"""Root-only Redis evidence helper for the release publication lock."""

import argparse
import json
import pathlib
import sys
import time


def client(args):
    sys.path.insert(0, args.lib_root)
    from search_indexctl import RedisClient

    password = pathlib.Path(args.password_file).read_text().strip()
    return RedisClient(args.host, args.port, password)


def snapshot(args):
    redis = client(args)
    token = redis.command("GET", args.key)
    value = {
        "ping": redis.command("PING"),
        "key": args.key,
        "token": token,
        "pttl_ms": redis.command("PTTL", args.key),
        "journal_length": redis.command("LLEN", args.journal_key),
        "captured_at_ns": time.time_ns(),
    }
    print(json.dumps(value, indent=2, sort_keys=True))


def observe(args):
    redis = client(args)
    samples = []
    for index in range(args.samples):
        samples.append(
            {
                "sequence": index + 1,
                "captured_at_ns": time.time_ns(),
                "token": redis.command("GET", args.key),
                "pttl_ms": redis.command("PTTL", args.key),
            }
        )
        if index + 1 < args.samples:
            time.sleep(args.interval_ms / 1000)
    positive = [item["pttl_ms"] for item in samples if item["pttl_ms"] > 0]
    rises = sum(1 for before, after in zip(positive, positive[1:]) if after > before + 40)
    tokens = {item["token"] for item in samples}
    result = {
        "schema": "redis_pttl_observation_v1",
        "key": args.key,
        "samples": samples,
        "positive_samples": len(positive),
        "renewal_rises": rises,
        "stable_nonempty_token": len(tokens) == 1 and None not in tokens,
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    if len(positive) != len(samples) or rises < args.minimum_rises or not result["stable_nonempty_token"]:
        return 1
    return 0


def duty(args):
    redis = client(args)
    samples = []
    for index in range(args.samples):
        samples.append({"sequence": index + 1, "captured_at_ns": time.time_ns(), "token": redis.command("GET", args.key)})
        if index + 1 < args.samples:
            time.sleep(args.interval_ms / 1000)
    occupied = [item for item in samples if item["token"] is not None]
    free = [item for item in samples if item["token"] is None]
    tokens = {item["token"] for item in occupied}
    transitions = sum(before["token"] != after["token"] for before, after in zip(samples, samples[1:]))
    result = {"schema":"redis_lock_duty_observation_v1","key":args.key,"interval_ms":args.interval_ms,"samples":samples,"occupied_samples":len(occupied),"free_samples":len(free),"duty_cycle":len(occupied)/len(samples),"distinct_owner_tokens":len(tokens),"state_transitions":transitions}
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


def journal(args):
    redis = client(args)
    raw = redis.command("LRANGE", args.journal_key, 0, -1) or []
    records = [json.loads(item) for item in raw]
    print(json.dumps(records, indent=2, sort_keys=True))


def get_key(args):
    value = client(args).command("GET", args.key)
    if value is not None:
        print(value)
        return 0
    return 1


def wait_absent(args):
    redis = client(args)
    deadline = time.monotonic() + args.timeout_seconds
    while time.monotonic() < deadline:
        if redis.command("GET", args.key) is None:
            print(f"KEY_ABSENT=1 key={args.key}")
            return 0
        time.sleep(0.05)
    print(f"KEY_ABSENT=0 key={args.key}")
    return 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--lib-root", required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--key", required=True)
    parser.add_argument("--journal-key", required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("snapshot").set_defaults(func=snapshot)
    observe_parser = commands.add_parser("observe")
    observe_parser.add_argument("--samples", type=int, default=12)
    observe_parser.add_argument("--interval-ms", type=int, default=100)
    observe_parser.add_argument("--minimum-rises", type=int, default=3)
    observe_parser.set_defaults(func=observe)
    duty_parser = commands.add_parser("duty")
    duty_parser.add_argument("--samples", type=int, default=400)
    duty_parser.add_argument("--interval-ms", type=int, default=3)
    duty_parser.set_defaults(func=duty)
    commands.add_parser("journal").set_defaults(func=journal)
    commands.add_parser("get-key").set_defaults(func=get_key)
    wait_parser = commands.add_parser("wait-absent")
    wait_parser.add_argument("--timeout-seconds", type=float, default=4.0)
    wait_parser.set_defaults(func=wait_absent)
    args = parser.parse_args()
    return int(args.func(args) or 0)


if __name__ == "__main__":
    raise SystemExit(main())
