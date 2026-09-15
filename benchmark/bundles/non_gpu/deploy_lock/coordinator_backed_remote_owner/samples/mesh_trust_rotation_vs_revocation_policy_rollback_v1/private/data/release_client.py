#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request


def find_client_config():
    current = pathlib.Path.cwd().resolve()
    for directory in [current, *current.parents]:
        candidate = directory / ".release" / "client.json"
        if candidate.is_file():
            return json.loads(candidate.read_text())
    raise SystemExit("release client configuration not found; run inside the provided workspace")


def request_json(url, method="GET", payload=None, timeout=8):
    body = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(url, data=body, method=method)
    request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, json.loads(response.read().decode())
    except urllib.error.HTTPError as exc:
        return exc.code, json.loads(exc.read().decode())


def status_command(config, endpoint):
    code, payload = request_json(config["coordinator_url"].rstrip("/") + endpoint)
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0 if code == 200 else 2


def release_command(config, args):
    descriptor = json.loads(pathlib.Path(args.descriptor).read_text())
    verification = json.loads(pathlib.Path(args.verification).read_text())
    run_id = f"{config['b_run_prefix']}{int(time.time())}-{os.getpid()}"
    request = {
        "resource_key": config["resource_key"],
        "run_id": run_id,
        "client_pid": os.getpid(),
        "operation": args.operation,
        "target_revision": args.revision,
        "descriptor": descriptor,
        "verification": verification,
        "wait_seconds": args.wait,
    }
    code, payload = request_json(
        config["coordinator_url"].rstrip("/") + "/release",
        method="POST",
        payload=request,
        timeout=args.wait + 8,
    )
    print(json.dumps(payload, indent=2, sort_keys=True))
    attempt_path = pathlib.Path(config["attempt_path"])
    attempt_path.parent.mkdir(parents=True, exist_ok=True)
    attempt_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    if code == 200 and payload.get("status") == "committed":
        receipt = pathlib.Path(args.receipt)
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
        return 0
    if payload.get("status") in {"coordinator_busy", "queued_without_grant"}:
        return 75
    return 2


def main():
    config = find_client_config()
    parser = argparse.ArgumentParser(prog=config["client_name"])
    sub = parser.add_subparsers(dest="command", required=True)
    show_status = sub.add_parser("status")
    show_status.set_defaults(func=lambda args: status_command(config, "/status"))
    audit = sub.add_parser("audit")
    audit.set_defaults(func=lambda args: status_command(config, "/audit"))
    for operation in ("deploy", "rollback"):
        action = sub.add_parser(operation)
        action.add_argument("--revision", required=True)
        action.add_argument("--descriptor", required=True)
        action.add_argument("--verification", required=True)
        action.add_argument("--receipt", required=True)
        action.add_argument("--wait", type=int, default=10)
        action.set_defaults(func=lambda args, op=operation: release_command(config, argparse.Namespace(**{**vars(args), "operation": op})))
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
