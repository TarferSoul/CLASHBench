#!/usr/bin/env python3
import argparse
import json

from backend_http import quote, request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend-url", required=True)
    parser.add_argument("--state-key", required=True)
    parser.add_argument("--what", choices=("state", "lock", "history", "sessions"), default="state")
    args = parser.parse_args()
    if args.what == "state":
        value = request(args.backend_url, "GET", "/v1/state?key=" + quote(args.state_key))
    elif args.what == "lock":
        value = request(args.backend_url, "GET", "/v1/lock/current?key=" + quote(args.state_key))
    elif args.what == "history":
        value = request(args.backend_url, "GET", "/v1/lock/history?key=" + quote(args.state_key))
    else:
        value = request(args.backend_url, "GET", "/v1/session/list")
    print(json.dumps(value, sort_keys=True, indent=2))


if __name__ == "__main__":
    main()

