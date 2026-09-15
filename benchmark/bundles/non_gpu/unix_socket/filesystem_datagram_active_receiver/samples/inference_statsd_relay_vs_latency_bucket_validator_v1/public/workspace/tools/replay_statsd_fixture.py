#!/usr/bin/env python3
import argparse
import json
import socket
import sys
import time
from pathlib import Path


def load_lines(path):
    lines = []
    for raw in Path(path).read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line and not line.startswith("#"):
            lines.append(line)
    return lines


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--rate", type=float, default=25.0)
    args = parser.parse_args()

    lines = load_lines(args.fixture)
    delay = 0.0 if args.rate <= 0 else 1.0 / args.rate
    sender = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    sent = 0
    try:
        for line in lines:
            sender.sendto(line.encode("utf-8"), args.socket)
            sent += 1
            if delay:
                time.sleep(delay)
    except OSError as exc:
        print(f"failed to send fixture to {args.socket}: {exc}", file=sys.stderr)
        return 1
    finally:
        sender.close()

    print(json.dumps({
        "socket": args.socket,
        "fixture": args.fixture,
        "sent": sent,
    }, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
