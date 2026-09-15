#!/usr/bin/env python3
"""Finite CAN-FD controller soak with device-backed progress."""

import argparse
import json
import os
import pathlib
import socket
import time


def health(path):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(2)
    client.connect(path)
    client.sendall(b'{"op":"health"}\n')
    response = b""
    while not response.endswith(b"\n"):
        response += client.recv(4096)
    client.close()
    return json.loads(response)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--shard", type=int, required=True)
    parser.add_argument("--steps", type=int, required=True)
    parser.add_argument("--interval", type=float, required=True)
    parser.add_argument("--progress", required=True)
    parser.add_argument("--artifact", required=True)
    args = parser.parse_args()
    device_socket = os.environ["CI_DEVICE_SOCKET"]
    progress = pathlib.Path(args.progress)
    artifact = pathlib.Path(args.artifact)
    progress.parent.mkdir(parents=True, exist_ok=True)
    device_id = None
    for step in range(1, args.steps + 1):
        response = health(device_socket)
        if not response.get("ok"):
            raise SystemExit(44)
        device_id = response["device_id"]
        progress.write_text(json.dumps({
            "workflow_id": os.environ["CI_WORKFLOW_ID"], "shard": args.shard,
            "state": "running", "completed_steps": step, "total_steps": args.steps,
            "successful_transactions": step, "device_id": device_id,
            "device_heartbeat": response["heartbeat"], "executor_id": os.environ["CI_EXECUTOR_ID"],
            "job_id": os.environ["CI_JOB_ID"], "lease_id": os.environ["CI_LEASE_ID"],
            "updated_at": time.time(),
        }, sort_keys=True) + "\n")
        time.sleep(args.interval)
    artifact.write_text(json.dumps({
        "complete": True, "workflow_id": os.environ["CI_WORKFLOW_ID"], "shard": args.shard,
        "device_id": device_id, "successful_transactions": args.steps,
        "executor_id": os.environ["CI_EXECUTOR_ID"], "job_id": os.environ["CI_JOB_ID"],
    }, sort_keys=True) + "\n")
    progress.write_text(json.dumps({
        "workflow_id": os.environ["CI_WORKFLOW_ID"], "shard": args.shard,
        "state": "completed", "completed_steps": args.steps, "total_steps": args.steps,
        "successful_transactions": args.steps, "device_id": device_id,
        "executor_id": os.environ["CI_EXECUTOR_ID"], "job_id": os.environ["CI_JOB_ID"],
        "lease_id": os.environ["CI_LEASE_ID"], "artifact": str(artifact),
        "updated_at": time.time(),
    }, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
