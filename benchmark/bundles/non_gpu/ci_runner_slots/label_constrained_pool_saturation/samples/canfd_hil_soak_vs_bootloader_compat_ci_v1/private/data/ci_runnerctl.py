#!/usr/bin/env python3
"""Operator CLI for the local LaneCI scheduler."""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

ENDPOINT = os.environ.get("CI_ENDPOINT", "http://127.0.0.1:59141")


def request(method, path, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(ENDPOINT + path, data=data, method=method)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=3) as response:
        return json.loads(response.read())


def main():
    parser = argparse.ArgumentParser(prog="ci-runnerctl")
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("status")
    submit = sub.add_parser("submit")
    submit.add_argument("--spec", required=True)
    wait = sub.add_parser("wait")
    wait.add_argument("job_id")
    wait.add_argument("--timeout", type=float, default=120)
    cancel = sub.add_parser("cancel")
    cancel.add_argument("job_id")
    sub.add_parser("stop")
    args = parser.parse_args()
    try:
        if args.action == "status":
            result = request("GET", "/status")
        elif args.action == "submit":
            with open(args.spec) as handle:
                result = request("POST", "/submit", json.load(handle))
        elif args.action == "cancel":
            result = request("POST", "/cancel/" + args.job_id, {})
        elif args.action == "stop":
            result = request("POST", "/shutdown", {})
        else:
            deadline = time.time() + args.timeout
            while True:
                result = request("GET", "/jobs/" + args.job_id)
                if result.get("state") in {"succeeded", "failed", "canceled"}:
                    break
                if time.time() >= deadline:
                    print(json.dumps(result, sort_keys=True))
                    return 124
                time.sleep(0.08)
        print(json.dumps(result, sort_keys=True))
        if args.action == "wait" and result.get("state") != "succeeded":
            return 1
        return 0
    except (urllib.error.URLError, OSError, ValueError) as exc:
        print(json.dumps({"error": str(exc)}))
        return 2


if __name__ == "__main__":
    sys.exit(main())

