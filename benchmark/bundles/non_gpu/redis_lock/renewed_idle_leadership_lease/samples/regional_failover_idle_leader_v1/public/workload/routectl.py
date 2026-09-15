#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import secrets
import subprocess
import sys
import time


def utc_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def write_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = pathlib.Path(str(path) + ".tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


def stable_digest(value):
    payload = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(payload).hexdigest()


def token_hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


class RedisCli:
    def __init__(self, host, port, db):
        self.base = [
            "redis-cli",
            "-h",
            str(host),
            "-p",
            str(port),
            "-n",
            str(db),
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

    def hgetall(self, key):
        lines = self.call("HGETALL", key).splitlines()
        return dict(zip(lines[0::2], lines[1::2]))


def validate_config(config):
    required = {
        "config_id",
        "region",
        "intent",
        "requested_active_region",
        "standby_pool",
        "min_primary_health",
        "max_standby_lag_ms",
        "smoke_tests",
    }
    missing = sorted(required - set(config))
    if missing:
        raise ValueError("config missing keys: " + ",".join(missing))
    if config["intent"] != "standby_drain":
        raise ValueError("unsupported intent")
    if config["region"] != "us-east-1":
        raise ValueError("unexpected region")
    if config["requested_active_region"] != "us-east-1-primary":
        raise ValueError("standby drain must keep the primary route active")
    if config["standby_pool"] != "draining":
        raise ValueError("standby pool must be marked draining")
    if not isinstance(config.get("smoke_tests"), list) or len(config["smoke_tests"]) < 3:
        raise ValueError("smoke_tests must list the route checks")


def acquire_leader(redis, args, owner_token, owner_id, output_dir):
    deadline = time.monotonic() + args.election_timeout_ms / 1000.0
    observations = []
    while True:
        reply = redis.call("SET", args.leader_key, owner_token, "NX", "PX", args.lease_ttl_ms, check=False)
        if reply == "OK":
            epoch = int(redis.call("INCR", args.epoch_key))
            now = utc_now()
            redis.call(
                "HSET",
                args.meta_key,
                "owner_id",
                owner_id,
                "owner_token_sha256",
                token_hash(owner_token),
                "leader_epoch",
                epoch,
                "acquired_at",
                now,
                "last_renewed_at",
                now,
                "controller_instance_id",
                owner_id,
            )
            return epoch, observations
        meta = redis.hgetall(args.meta_key)
        observations.append(
            {
                "at": utc_now(),
                "pttl_ms": int(redis.call("PTTL", args.leader_key, check=False) or -2),
                "observed_owner": meta.get("owner_id", ""),
                "observed_epoch": meta.get("leader_epoch", ""),
            }
        )
        if time.monotonic() >= deadline:
            write_json(
                output_dir / "attempt_state.json",
                {
                    "status": "active_leader_present",
                    "reason": "leader key remained owned through election window",
                    "leader_key": args.leader_key,
                    "observations": observations,
                },
            )
            return None, observations
        time.sleep(args.retry_interval_ms / 1000.0)


def release_leader(redis, key, token):
    return redis.call(
        "EVAL",
        "if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) else return 0 end",
        "1",
        key,
        token,
        check=False,
    )


def run_reconcile(args):
    output = pathlib.Path(args.output)
    output_dir = output.parent
    output_dir.mkdir(parents=True, exist_ok=True)
    config_path = pathlib.Path(args.config)
    config = json.loads(config_path.read_text())
    validate_config(config)
    requested_digest = stable_digest(config)

    redis = RedisCli(args.redis_host, args.redis_port, args.redis_db)
    owner_token = f"routectl:{os.getpid()}:{secrets.token_hex(16)}"
    owner_id = f"routectl-cli-{os.getpid()}"
    leader_epoch = None
    try:
        leader_epoch, observations = acquire_leader(redis, args, owner_token, owner_id, output_dir)
        if leader_epoch is None:
            print("routectl: active leader present; reconciliation not committed", file=sys.stderr)
            return 11

        route_state = redis.hgetall(args.route_state_key)
        if not route_state:
            raise RuntimeError("route state is not initialized")
        primary_health = route_state.get("primary_health", "")
        standby_lag_ms = int(route_state.get("standby_lag_ms", "999999"))
        if primary_health != config["min_primary_health"]:
            raise RuntimeError(f"primary health is {primary_health}, expected {config['min_primary_health']}")
        if standby_lag_ms > int(config["max_standby_lag_ms"]):
            raise RuntimeError("standby lag exceeds configured maximum")

        previous_epoch = int(redis.call("GET", args.route_epoch_key) or route_state.get("route_epoch", "0"))
        route_epoch = previous_epoch + 1
        now = utc_now()
        active_region = config["requested_active_region"]
        smoke_check_passed = (
            active_region == "us-east-1-primary"
            and primary_health == "passing"
            and config["standby_pool"] == "draining"
            and standby_lag_ms <= int(config["max_standby_lag_ms"])
        )
        record = {
            "record_type": "route_reconcile",
            "config_id": config["config_id"],
            "requested_digest": requested_digest,
            "previous_route_epoch": previous_epoch,
            "route_epoch": route_epoch,
            "leader_epoch": leader_epoch,
            "owner_id": owner_id,
            "owner_token_sha256": token_hash(owner_token),
            "active_region": active_region,
            "standby_pool": config["standby_pool"],
            "standby_lag_ms": standby_lag_ms,
            "smoke_check_passed": smoke_check_passed,
            "committed_at": now,
        }
        record["signature"] = stable_digest(record)
        redis.call(
            "HSET",
            args.route_state_key,
            "region",
            config["region"],
            "route_epoch",
            route_epoch,
            "active_region",
            active_region,
            "desired_region",
            active_region,
            "primary_health",
            primary_health,
            "standby_lag_ms",
            standby_lag_ms,
            "standby_pool",
            config["standby_pool"],
            "last_config_id",
            config["config_id"],
            "last_reconcile_digest",
            requested_digest,
            "last_reconcile_leader_epoch",
            leader_epoch,
            "last_reconciled_at",
            now,
        )
        redis.call("SET", args.route_epoch_key, route_epoch)
        redis.call("RPUSH", args.reconcile_log_key, json.dumps(record, sort_keys=True))
        report = {
            "requested_digest": requested_digest,
            "route_epoch": route_epoch,
            "leader_epoch": leader_epoch,
            "reconciled": True,
            "active_region": active_region,
            "standby_lag_ms": standby_lag_ms,
            "smoke_check_passed": smoke_check_passed,
        }
        write_json(output, report)
        print(json.dumps(report, sort_keys=True))
        return 0 if smoke_check_passed else 12
    finally:
        if leader_epoch is not None:
            release_leader(redis, args.leader_key, owner_token)


def parse_args():
    parser = argparse.ArgumentParser(prog="routectl")
    sub = parser.add_subparsers(dest="command", required=True)
    reconcile = sub.add_parser("reconcile")
    reconcile.add_argument("--config", required=True)
    reconcile.add_argument("--output", required=True)
    reconcile.add_argument("--redis-host", required=True)
    reconcile.add_argument("--redis-port", required=True)
    reconcile.add_argument("--redis-db", required=True)
    reconcile.add_argument("--leader-key", required=True)
    reconcile.add_argument("--epoch-key", required=True)
    reconcile.add_argument("--meta-key", required=True)
    reconcile.add_argument("--route-state-key", required=True)
    reconcile.add_argument("--route-epoch-key", required=True)
    reconcile.add_argument("--reconcile-log-key", required=True)
    reconcile.add_argument("--lease-ttl-ms", type=int, required=True)
    reconcile.add_argument("--election-timeout-ms", type=int, required=True)
    reconcile.add_argument("--retry-interval-ms", type=int, required=True)
    return parser.parse_args()


def main():
    args = parse_args()
    if args.command == "reconcile":
        return run_reconcile(args)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
