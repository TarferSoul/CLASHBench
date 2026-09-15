#!/usr/bin/env python3
"""Command-line client for ForgeCI Local Runner Service."""

import argparse
import json
import os
import pathlib
import socket
import sys
import time


def default_socket():
    configured = os.environ.get("FORGECI_SOCKET")
    if configured:
        return configured
    path = pathlib.Path("/etc/forgeci/socket")
    if path.is_file():
        return path.read_text().strip()
    raise SystemExit("ForgeCI socket is not configured")


def request(socket_path, payload):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(2)
    client.connect(socket_path)
    client.sendall((json.dumps(payload, separators=(",", ":")) + "\n").encode())
    chunks = []
    while True:
        chunk = client.recv(65536)
        if not chunk:
            break
        chunks.append(chunk)
        if b"\n" in chunk:
            break
    response = json.loads(b"".join(chunks))
    if not response.get("ok"):
        raise SystemExit(response.get("error", "request failed"))
    return response["result"]


def emit(value):
    print(json.dumps(value, sort_keys=True, indent=2))


def main():
    parser = argparse.ArgumentParser(prog="forgeci")
    parser.add_argument("--socket", default="")
    sub = parser.add_subparsers(dest="action", required=True)
    status = sub.add_parser("status")
    status.add_argument("--job", default="")
    submit = sub.add_parser("submit")
    submit.add_argument("--job", required=True)
    submit.add_argument("--workflow", required=True)
    submit.add_argument("--cwd", required=True)
    submit.add_argument("command", nargs=argparse.REMAINDER)
    wait = sub.add_parser("wait")
    wait.add_argument("--job", required=True)
    wait.add_argument("--timeout", type=float, default=180)
    cancel = sub.add_parser("cancel")
    cancel.add_argument("--job", required=True)
    args = parser.parse_args()
    socket_path = args.socket or default_socket()
    if args.action == "status":
        emit(request(socket_path, {"action": "status", "job_id": args.job or None}))
    elif args.action == "submit":
        command = args.command
        if command and command[0] == "--":
            command = command[1:]
        if not command:
            raise SystemExit("command is required after --")
        emit(request(socket_path, {
            "action": "submit",
            "job_id": args.job,
            "workflow_id": args.workflow,
            "cwd": args.cwd,
            "command": command,
        }))
    elif args.action == "cancel":
        emit(request(socket_path, {"action": "cancel", "job_id": args.job}))
    else:
        deadline = time.monotonic() + args.timeout
        while True:
            result = request(socket_path, {"action": "status", "job_id": args.job})
            state = result["job"]["state"]
            if state in {"succeeded", "failed", "cancelled"}:
                emit(result)
                raise SystemExit(0 if state == "succeeded" else 1)
            if time.monotonic() >= deadline:
                emit(result)
                raise SystemExit(124)
            time.sleep(0.2)


if __name__ == "__main__":
    main()

