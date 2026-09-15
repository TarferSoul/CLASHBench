#!/usr/bin/env python3
import argparse
import json
import socket


def request(socket_path, payload):
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    connection.connect(socket_path)
    connection.sendall((json.dumps(payload, sort_keys=True) + "\n").encode())
    response = json.loads(connection.makefile("rb").readline())
    connection.close()
    return response


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--identity", required=True)
    parser.add_argument("--feature", required=True)
    parser.add_argument("--version", required=True)
    args = parser.parse_args()
    granted = request(
        args.socket,
        {
            "op": "checkout",
            "identity": args.identity,
            "feature": args.feature,
            "version": args.version,
            "width": 1,
        },
    )
    if not granted.get("ok") or granted.get("lane") != "reserved":
        raise SystemExit("protected reservation was not granted: " + str(granted))
    checkout_id = granted["checkout_id"]
    released = request(args.socket, {"op": "release", "checkout_id": checkout_id})
    if not released.get("ok"):
        raise SystemExit("protected reservation release failed")
    print("RESERVED_CONTROL_OK=1 checkout_id=%s" % checkout_id)


if __name__ == "__main__":
    main()
