#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import signal
import time
import urllib.error
import urllib.request


stopping = False


def request_json(url, payload, timeout=5):
    request = urllib.request.Request(url, data=json.dumps(payload).encode(), method="POST")
    request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, json.loads(response.read().decode())
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read().decode())


def main():
    parser = argparse.ArgumentParser(prog="catalog-reconcile-worker")
    parser.add_argument("--config", required=True)
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("--stop-file", required=True)
    args = parser.parse_args()
    config = json.loads(pathlib.Path(args.config).read_text())
    pathlib.Path(args.pid_file).write_text(str(os.getpid()) + "\n")

    def stop(*_):
        global stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    base = config["coordinator_url"].rstrip("/")
    acquire = {
        "resource_key": config["resource_key"],
        "run_id": config["run_id"],
        "executor_pid": os.getpid(),
    }
    status, response = request_json(base + "/owner/acquire", acquire)
    if status != 200 or response.get("status") != "granted":
        print(json.dumps(response, sort_keys=True), flush=True)
        return 1
    fence = int(response["fencing_revision"])
    current_metrics = {}
    stages = config["stages"]
    index = 0
    try:
        while not stopping and not pathlib.Path(args.stop_file).exists():
            if index < len(stages):
                stage = stages[index]
                index += 1
                stage_name = stage["name"]
                current_metrics = dict(stage["metrics"])
            else:
                stage_name = config["loop_stage"]
                for key, increment in config["loop_increments"].items():
                    current_metrics[key] = int(current_metrics.get(key, 0)) + int(increment)
            heartbeat = {
                "resource_key": config["resource_key"],
                "run_id": config["run_id"],
                "fencing_revision": fence,
                "stage": stage_name,
                "metrics": current_metrics,
            }
            status, response = request_json(base + "/owner/heartbeat", heartbeat)
            if status != 200:
                print(json.dumps(response, sort_keys=True), flush=True)
                return 2
            print(
                json.dumps(
                    {
                        "run_id": config["run_id"],
                        "fencing_revision": fence,
                        "stage": stage_name,
                        "metrics": current_metrics,
                        "heartbeat_sequence": response["heartbeat_sequence"],
                    },
                    sort_keys=True,
                ),
                flush=True,
            )
            time.sleep(float(config.get("heartbeat_interval_seconds", 0.35)))
    finally:
        try:
            request_json(
                base + "/owner/release",
                {
                    "resource_key": config["resource_key"],
                    "run_id": config["run_id"],
                    "fencing_revision": fence,
                    "reason": "normal_executor_shutdown",
                },
            )
        except Exception:
            pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
