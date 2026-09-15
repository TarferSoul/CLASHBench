#!/usr/bin/env python3
import argparse
import hashlib
import http.server
import json
import os
import pathlib
import secrets
import signal
import subprocess
import threading
import time


def utc_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def write_json(path, value):
    path = pathlib.Path(path)
    tmp = pathlib.Path(str(path) + ".tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


def token_hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


class RedisCli:
    def __init__(self, host, port, db):
        self.base = ["redis-cli", "-h", host, "-p", str(port), "-n", str(db), "--raw"]

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


class HealthHandler(http.server.BaseHTTPRequestHandler):
    controller = None

    def do_GET(self):
        if self.path not in ("/healthz", "/status"):
            self.send_response(404)
            self.end_headers()
            return
        payload = self.controller.health_payload()
        body = json.dumps(payload, sort_keys=True).encode()
        self.send_response(200 if payload.get("healthy") else 503)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        return


class Controller:
    def __init__(self, args):
        self.args = args
        self.redis = RedisCli(args.redis_host, args.redis_port, args.redis_db)
        self.run_root = pathlib.Path(args.run_root)
        self.owner_token = secrets.token_hex(24)
        self.owner_hash = token_hash(self.owner_token)
        self.instance_id = f"failover-controller-{secrets.token_hex(8)}"
        self.leader_epoch = None
        self.heartbeat_seq = 0
        self.observation_seq = 0
        self.last_status = {}
        self.healthy = False
        self.stop_requested = False

    def acquire(self):
        reply = self.redis.call(
            "SET",
            self.args.leader_key,
            self.owner_token,
            "NX",
            "PX",
            self.args.lease_ttl_ms,
            check=False,
        )
        if reply != "OK":
            raise RuntimeError("leader key is already owned")
        self.leader_epoch = int(self.redis.call("INCR", self.args.epoch_key))
        now = utc_now()
        self.redis.call(
            "HSET",
            self.args.meta_key,
            "owner_id",
            "failover-controller",
            "owner_token_sha256",
            self.owner_hash,
            "leader_epoch",
            self.leader_epoch,
            "acquired_at",
            now,
            "last_renewed_at",
            now,
            "controller_instance_id",
            self.instance_id,
            "region",
            self.args.region,
        )
        (self.run_root / "controller.pid").write_text(str(os.getpid()) + "\n")
        (self.run_root / "owner_token.txt").write_text(self.owner_token + "\n")
        os.chmod(self.run_root / "owner_token.txt", 0o600)
        (self.run_root / "controller_instance_id.txt").write_text(self.instance_id + "\n")

    def renew(self):
        result = self.redis.call(
            "EVAL",
            "if redis.call('GET', KEYS[1]) == ARGV[1] then redis.call('PEXPIRE', KEYS[1], ARGV[2]); return redis.call('PTTL', KEYS[1]); else return -1 end",
            "1",
            self.args.leader_key,
            self.owner_token,
            self.args.lease_ttl_ms,
            check=False,
        )
        if int(result or -1) <= 0:
            raise RuntimeError("lost leader token during renewal")
        self.redis.call("HSET", self.args.meta_key, "last_renewed_at", utc_now())
        return int(result)

    def release(self):
        self.redis.call(
            "EVAL",
            "if redis.call('GET', KEYS[1]) == ARGV[1] then return redis.call('DEL', KEYS[1]) else return 0 end",
            "1",
            self.args.leader_key,
            self.owner_token,
            check=False,
        )
        self.redis.call("HSET", self.args.meta_key, "released_at", utc_now(), "released_by", self.instance_id, check=False)

    def observe(self):
        route = self.redis.hgetall(self.args.route_state_key)
        if not route:
            raise RuntimeError("route state missing")
        self.heartbeat_seq += 1
        self.observation_seq += 1
        pttl_ms = int(self.redis.call("PTTL", self.args.leader_key, check=False) or -2)
        sample_id = f"{self.args.region}-primary-{self.observation_seq:06d}"
        status = {
            "healthy": True,
            "controller_pid": os.getpid(),
            "controller_instance_id": self.instance_id,
            "leader_epoch": self.leader_epoch,
            "leader": True,
            "region": self.args.region,
            "active_region": route.get("active_region", ""),
            "desired_region": route.get("desired_region", ""),
            "primary_health": route.get("primary_health", ""),
            "primary_health_sample_id": sample_id,
            "standby_lag_ms": int(route.get("standby_lag_ms", "0")),
            "standby_pool": route.get("standby_pool", ""),
            "route_epoch": int(route.get("route_epoch", "0")),
            "reconcile_cursor": f"{self.args.region}:{self.observation_seq:06d}",
            "observation_seq": self.observation_seq,
            "heartbeat_seq": self.heartbeat_seq,
            "pttl_ms": pttl_ms,
            "owner_token_sha256": self.owner_hash,
            "last_observed_at": utc_now(),
        }
        self.redis.call(
            "HSET",
            self.args.status_key,
            *[item for pair in status.items() for item in pair],
        )
        self.redis.call("RPUSH", self.args.observation_log_key, json.dumps(status, sort_keys=True))
        self.redis.call("LTRIM", self.args.observation_log_key, "-80", "-1")
        self.last_status = status
        self.healthy = True
        write_json(self.run_root / "failover_status.json", status)

    def health_payload(self):
        return {
            "healthy": self.healthy and not self.stop_requested,
            "controller_instance_id": self.instance_id,
            "leader_epoch": self.leader_epoch,
            "heartbeat_seq": self.heartbeat_seq,
            "observation_seq": self.observation_seq,
            "last_status": self.last_status,
        }

    def serve_health(self):
        HealthHandler.controller = self
        server = http.server.ThreadingHTTPServer((self.args.health_host, self.args.health_port), HealthHandler)
        server.timeout = 0.2
        while not self.stop_requested:
            server.handle_request()
        server.server_close()

    def run(self):
        self.run_root.mkdir(parents=True, exist_ok=True)
        self.acquire()
        thread = threading.Thread(target=self.serve_health, daemon=True)
        thread.start()
        next_renew = time.monotonic() + self.args.renew_interval_ms / 1000.0
        while not self.stop_requested:
            now = time.monotonic()
            if now >= next_renew:
                self.renew()
                next_renew = now + self.args.renew_interval_ms / 1000.0
            self.observe()
            time.sleep(0.5)
        self.healthy = False
        self.release()


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--redis-host", required=True)
    parser.add_argument("--redis-port", required=True)
    parser.add_argument("--redis-db", required=True)
    parser.add_argument("--region", required=True)
    parser.add_argument("--leader-key", required=True)
    parser.add_argument("--epoch-key", required=True)
    parser.add_argument("--meta-key", required=True)
    parser.add_argument("--status-key", required=True)
    parser.add_argument("--route-state-key", required=True)
    parser.add_argument("--observation-log-key", required=True)
    parser.add_argument("--run-root", required=True)
    parser.add_argument("--lease-ttl-ms", type=int, required=True)
    parser.add_argument("--renew-interval-ms", type=int, required=True)
    parser.add_argument("--health-host", required=True)
    parser.add_argument("--health-port", type=int, required=True)
    return parser.parse_args()


def main():
    args = parse_args()
    controller = Controller(args)

    def handle_stop(signum, frame):
        controller.stop_requested = True

    signal.signal(signal.SIGTERM, handle_stop)
    signal.signal(signal.SIGINT, handle_stop)
    controller.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

