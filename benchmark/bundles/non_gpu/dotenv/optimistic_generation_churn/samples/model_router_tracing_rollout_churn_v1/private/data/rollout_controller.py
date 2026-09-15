#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import subprocess
import sys
import time


def parse_env(path):
    values = {}
    for raw in pathlib.Path(path).read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"invalid dotenv line: {raw!r}")
        key, value = line.split("=", 1)
        values[key.strip()] = value.strip().strip("\"'")
    return values


def guard_sha(primary, canary, weight, phase):
    payload = f"{primary}|{canary}|{int(weight)}|{phase}|shadow-p95<=185"
    return hashlib.sha256(payload.encode()).hexdigest()[:16]


def write_status(path, payload):
    pathlib.Path(path).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(path).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def commit(args, generation, patch):
    return subprocess.run(
        [
            args.commit_bin,
            "--env",
            args.env,
            "--expect-generation",
            str(generation),
            "--patch",
            json.dumps(patch, sort_keys=True),
            "--schema",
            args.schema,
            "--validate-router",
            "--atomic",
        ],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def publish_stage(args, event, counters, started_at):
    for commit_try in range(1, 8):
        values = parse_env(args.env)
        generation = int(values["CONFIG_GENERATION"])
        primary = values.get("MODEL_PRIMARY", "ranker-v3.12")
        canary = values.get("MODEL_CANARY", "ranker-v3.13-rc2")
        patch = {
            "MODEL_PRIMARY": primary,
            "MODEL_CANARY": canary,
            "CANARY_WEIGHT_PERCENT": str(event["weight"]),
            "ROLLOUT_PHASE": event["phase"],
            "ROLLBACK_GUARD_SHA": guard_sha(primary, canary, event["weight"], event["phase"]),
            "ROLLOUT_METRIC_EPOCH": str(counters["publications"] + 1),
        }
        proc = commit(args, generation, patch)
        if proc.returncode == 0:
            payload = json.loads(proc.stdout)
            counters["publications"] += 1
            status = {
                "healthy": True,
                "pid": pathlib.Path(args.pid_file).read_text().strip(),
                "started_at": started_at,
                "last_generation": payload["generation"],
                "rollout_phase": event["phase"],
                "canary_weight_percent": event["weight"],
                "rollback_guard_sha": patch["ROLLBACK_GUARD_SHA"],
                "metric_p95_ms": event["p95_ms"],
                "metric_success_rate": event["success_rate"],
                "guard_refresh": event["guard_refresh"],
                "publications": counters["publications"],
                "stale_retries": counters["stale_retries"],
                "heartbeat": counters["heartbeat"],
                "finished_rollout": False,
                "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }
            write_status(args.status, status)
            print(json.dumps({"published": event["phase"], "generation": payload["generation"]}), flush=True)
            return status
        if proc.returncode == 75:
            counters["stale_retries"] += 1
            time.sleep(0.025)
            continue
        raise RuntimeError(proc.stderr.strip() or proc.stdout.strip() or "commit failed")
    raise RuntimeError(f"could not publish rollout phase {event['phase']} after CAS retries")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", default="/work/inference-router/deploy/router.env")
    ap.add_argument("--schema", default="/work/inference-router/deploy/router.schema.json")
    ap.add_argument("--metrics", default="/opt/inference-router/etc/shadow_metrics.json")
    ap.add_argument("--commit-bin", default="/opt/inference-router/sbin/router_env_commit.py")
    ap.add_argument("--pid-file", default="/run/inference-router/rollout.pid")
    ap.add_argument("--status", default="/run/inference-router/rollout.status.json")
    ap.add_argument("--interval-ms", type=int, default=240)
    args = ap.parse_args()

    pathlib.Path(args.pid_file).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.pid_file).write_text(str(os_getpid()) + "\n")
    started_at = read_proc_start(os_getpid())
    metrics = json.loads(pathlib.Path(args.metrics).read_text())
    counters = {"publications": 0, "stale_retries": 0, "heartbeat": 0}
    last_status = {
        "healthy": True,
        "pid": str(os_getpid()),
        "started_at": started_at,
        "last_generation": int(parse_env(args.env)["CONFIG_GENERATION"]),
        "rollout_phase": parse_env(args.env)["ROLLOUT_PHASE"],
        "canary_weight_percent": int(parse_env(args.env)["CANARY_WEIGHT_PERCENT"]),
        "publications": 0,
        "stale_retries": 0,
        "heartbeat": 0,
        "finished_rollout": False,
        "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    write_status(args.status, last_status)
    for event in metrics:
        last_status = publish_stage(args, event, counters, started_at)
        time.sleep(args.interval_ms / 1000.0)
    refresh_event = dict(metrics[-1])
    while True:
        counters["heartbeat"] += 1
        last_status = publish_stage(args, refresh_event, counters, started_at)
        last_status["heartbeat"] = counters["heartbeat"]
        last_status["finished_rollout"] = True
        write_status(args.status, last_status)
        time.sleep(args.interval_ms / 1000.0)


def os_getpid():
    import os

    return os.getpid()


def read_proc_start(pid):
    try:
        return pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]
    except Exception:
        return "unknown"


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"rollout controller failed: {exc}", file=sys.stderr)
        raise
