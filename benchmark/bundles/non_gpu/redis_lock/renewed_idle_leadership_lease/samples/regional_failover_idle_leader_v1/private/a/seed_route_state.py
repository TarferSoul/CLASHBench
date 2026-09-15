#!/usr/bin/env python3
import json
import os
import pathlib
import subprocess
import time


class RedisCli:
    def __init__(self):
        self.base = [
            "redis-cli",
            "-h",
            os.environ["REDIS_HOST"],
            "-p",
            os.environ["REDIS_PORT"],
            "-n",
            os.environ.get("REDIS_DB", "0"),
            "--raw",
        ]

    def call(self, *args, check=True):
        proc = subprocess.run(
            self.base + [str(arg) for arg in args],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
        )
        if check and proc.returncode != 0:
            raise RuntimeError(proc.stderr.strip() or f"redis-cli rc={proc.returncode}")
        return proc.stdout.strip()


def main():
    fixture_path = pathlib.Path(os.environ["PRIVATE_CASE"]) / "data" / "initial_route_state.json"
    fixture = json.loads(fixture_path.read_text())
    redis = RedisCli()
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    if os.environ.get("RESET_ROUTE_REDIS") == "1":
        redis.call("FLUSHDB")
    redis.call(
        "HSET",
        os.environ["ROUTE_STATE_KEY"],
        "region",
        fixture["region"],
        "route_epoch",
        fixture["route_epoch"],
        "active_region",
        fixture["active_region"],
        "desired_region",
        fixture["desired_region"],
        "primary_health",
        fixture["primary_health"],
        "primary_sample_id",
        fixture["primary_sample_id"],
        "standby_lag_ms",
        fixture["standby_lag_ms"],
        "standby_pool",
        fixture["standby_pool"],
        "router_config_version",
        fixture["router_config_version"],
        "smoke_endpoint",
        fixture["smoke_endpoint"],
        "seeded_at",
        now,
    )
    redis.call("SET", os.environ["ROUTE_EPOCH_KEY"], fixture["route_epoch"])
    print(f"SEEDED_ROUTE_STATE=1 route_epoch={fixture['route_epoch']}")


if __name__ == "__main__":
    raise SystemExit(main())

