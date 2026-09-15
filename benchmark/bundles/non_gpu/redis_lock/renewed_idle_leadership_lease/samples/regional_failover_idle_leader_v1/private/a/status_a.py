#!/usr/bin/env python3
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import urllib.request


def token_hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


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

    def hgetall(self, key):
        lines = self.call("HGETALL", key).splitlines()
        return dict(zip(lines[0::2], lines[1::2]))


def int_value(value, default=0):
    try:
        return int(value)
    except Exception:
        return default


def proc_stat(pid):
    text = pathlib.Path(f"/proc/{pid}/stat").read_text()
    tail = text[text.rfind(")") + 2 :].split()
    return {
        "state": tail[0],
        "ppid": int(tail[1]),
        "process_group": int(tail[2]),
        "process_start_ticks": int(tail[19]),
    }


def proc_cmdline(pid):
    data = pathlib.Path(f"/proc/{pid}/cmdline").read_bytes()
    return data.replace(b"\0", b" ").decode(errors="replace").strip()


def read_health():
    url = f"http://{os.environ['A_HEALTH_HOST']}:{os.environ['A_HEALTH_PORT']}/healthz"
    with urllib.request.urlopen(url, timeout=1.5) as response:
        return json.loads(response.read().decode())


def collect_status():
    private_case = pathlib.Path(os.environ["PRIVATE_CASE"])
    fixture_env = private_case / "fixture.env"
    if fixture_env.exists():
        for line in fixture_env.read_text().splitlines():
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            os.environ.setdefault(key, value)

    run_root = pathlib.Path(os.environ["A_RUN_ROOT"])
    pid = int((run_root / "controller.pid").read_text().strip())
    owner_token = (run_root / "owner_token.txt").read_text().strip()
    owner_sha = token_hash(owner_token)
    redis = RedisCli()
    current_token = redis.call("GET", os.environ["LEADER_KEY"], check=False)
    pttl_ms = int_value(redis.call("PTTL", os.environ["LEADER_KEY"], check=False), -2)
    meta = redis.hgetall(os.environ["META_KEY"])
    status = redis.hgetall(os.environ["STATUS_KEY"])
    route_state = redis.hgetall(os.environ["ROUTE_STATE_KEY"])
    health = read_health()
    stat = proc_stat(pid)
    result = {
        "pid": pid,
        "cmdline": proc_cmdline(pid),
        "process_state": stat["state"],
        "process_group": stat["process_group"],
        "process_start_ticks": stat["process_start_ticks"],
        "controller_instance_id": meta.get("controller_instance_id", ""),
        "health_instance_id": health.get("controller_instance_id", ""),
        "token_hash": owner_sha,
        "redis_token_hash": token_hash(current_token) if current_token else "",
        "leader_epoch": int_value(meta.get("leader_epoch"), -1),
        "status_leader_epoch": int_value(status.get("leader_epoch"), -1),
        "pttl_ms": pttl_ms,
        "heartbeat_seq": int_value(status.get("heartbeat_seq"), -1),
        "observation_seq": int_value(status.get("observation_seq"), -1),
        "reconcile_cursor": status.get("reconcile_cursor", ""),
        "primary_health": status.get("primary_health", ""),
        "primary_health_sample_id": status.get("primary_health_sample_id", ""),
        "standby_lag_ms": int_value(status.get("standby_lag_ms"), -1),
        "active_region": route_state.get("active_region", ""),
        "desired_region": route_state.get("desired_region", ""),
        "standby_pool": route_state.get("standby_pool", ""),
        "route_epoch": int_value(route_state.get("route_epoch"), -1),
        "meta": meta,
        "status": status,
        "route_state": route_state,
        "health": health,
    }
    result["healthy"] = (
        result["process_state"] != "Z"
        and current_token == owner_token
        and result["pttl_ms"] > 0
        and result["controller_instance_id"] == result["health_instance_id"]
        and result["leader_epoch"] == result["status_leader_epoch"]
        and result["primary_health"] == "passing"
        and health.get("healthy") is True
    )
    return result


def main():
    try:
        status = collect_status()
    except Exception as exc:
        print(json.dumps({"healthy": False, "error": type(exc).__name__, "detail": str(exc)}))
        return 1
    print(json.dumps(status, indent=2, sort_keys=True))
    return 0 if status.get("healthy") else 1


if __name__ == "__main__":
    raise SystemExit(main())
