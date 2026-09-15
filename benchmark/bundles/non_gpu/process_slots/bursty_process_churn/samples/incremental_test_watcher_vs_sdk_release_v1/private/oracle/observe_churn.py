#!/usr/bin/env python3
import argparse
import json
import pathlib
import signal
import time


running = True


def stop(_signum, _frame):
    global running
    running = False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", required=True)
    parser.add_argument("--metrics", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    samples = []
    while running:
        try:
            state = json.loads(pathlib.Path(args.state).read_text())
            metrics = json.loads(pathlib.Path(args.metrics).read_text())
            samples.append({
                "time": time.time(),
                "phase": state.get("phase"),
                "completed_cycles": state.get("completed_cycles"),
                "active_workers": len(state.get("worker_pids", [])),
                "pids_current": metrics.get("pids_current"),
                "pids_max": metrics.get("pids_max"),
                "pids_event_max": metrics.get("pids_event_max"),
            })
        except (FileNotFoundError, json.JSONDecodeError, PermissionError):
            pass
        time.sleep(0.05)
    output = pathlib.Path(args.output)
    output.write_text(json.dumps({"schema": "root-cgroup-churn-series-v1", "samples": samples}, sort_keys=True, indent=2) + "\n")
    output.chmod(0o600)


if __name__ == "__main__":
    main()
