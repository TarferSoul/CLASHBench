#!/usr/bin/env python3
import argparse
import json
import os
import time
from urllib import request


def write_state(path, payload):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, sort_keys=True)
        handle.write("\n")
    os.replace(tmp, path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--service", required=True)
    parser.add_argument("--message", required=True)
    parser.add_argument("--path", required=True)
    parser.add_argument("--context-key", required=True)
    parser.add_argument("--context-value", required=True)
    parser.add_argument("--header-name", required=True)
    parser.add_argument("--header-value", required=True)
    parser.add_argument("--state-file", required=True)
    parser.add_argument("--interval", type=float, default=0.25)
    args = parser.parse_args()
    successes = 0
    failures = 0
    while True:
        try:
            req = request.Request(f"{args.url}{args.path}?sequence={successes + failures + 1}", headers={"Host": args.host})
            with request.urlopen(req, timeout=1.0) as response:
                body = json.loads(response.read().decode("utf-8"))
                header = response.headers.get(args.header_name, "")
            if (
                response.status == 200
                and body.get("service") == args.service
                and body.get("message") == args.message
                and body.get(args.context_key) == args.context_value
                and header == args.header_value
            ):
                successes += 1
            else:
                failures += 1
        except Exception:
            failures += 1
        write_state(
            args.state_file,
            {
                "successes": successes,
                "failures": failures,
                "host": args.host,
                "service": args.service,
                "updated_at": time.time(),
            },
        )
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
