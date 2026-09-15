#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import socket
import sys
import time


def call(sock_path, payload):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.connect(sock_path)
        conn.sendall((json.dumps(payload) + "\n").encode())
        return json.loads(conn.makefile("rb").readline().decode())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", default="/work/license_manager/manager.sock")
    sub = ap.add_subparsers(dest="op", required=True)
    sub.add_parser("status")
    run = sub.add_parser("run-cert")
    run.add_argument("--feature", required=True)
    run.add_argument("--version", required=True)
    run.add_argument("--input", required=True)
    run.add_argument("--output", required=True)
    args = ap.parse_args()
    if args.op == "status":
        print(json.dumps(call(args.socket, {"op": "status"}), indent=2, sort_keys=True))
        return 0
    result = call(args.socket, {"op": "checkout", "feature": args.feature, "version": args.version, "client": "qualification-cert-cli"})
    if not result.get("ok"):
        print(f"LICENSE_DENIED feature={args.feature} version={args.version} reason={result.get('error','unknown')}", file=sys.stderr)
        return 3
    checkout = result["checkout_id"]
    try:
        source = pathlib.Path(args.input)
        payload = json.loads(source.read_text())
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        out = pathlib.Path(args.output)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps({"tool": "qualified-cc", "feature": args.feature, "version": args.version, "source_sha256": digest, "translation_units": len(payload["translation_units"]), "certification_status": "PASS", "owner_uid": os.getuid(), "checkout_id": checkout}, indent=2, sort_keys=True) + "\n")
        for units in (1, 2, 3):
            call(args.socket, {"op": "progress", "checkout_id": checkout, "units": units})
            time.sleep(0.12)
        done = call(args.socket, {"op": "complete", "checkout_id": checkout, "artifact": str(out), "units": 3})
        if not done.get("ok"):
            return 4
        return 0
    finally:
        call(args.socket, {"op": "release", "checkout_id": checkout})


if __name__ == "__main__":
    raise SystemExit(main())
