#!/usr/bin/env python3
"""Transfer a bounded engineering artifact set and write receiver-verified evidence."""
import argparse
import hashlib
import json
import socket
import time
from pathlib import Path

def make_payload(label, size):
    seed = hashlib.sha256(label.encode()).digest()
    return (seed * ((size // len(seed)) + 1))[:size]

def send_part(host, port, artifact, revision, payload, deadline):
    digest = hashlib.sha256(payload).hexdigest()
    remaining = max(0.05, deadline - time.monotonic())
    with socket.create_connection((host, port), timeout=remaining) as sock:
        sock.settimeout(remaining)
        header = {"kind": "release-part", "name": artifact, "revision": revision, "size": len(payload), "sha256": digest}
        sock.sendall((json.dumps(header) + "\n").encode() + payload)
        response = b""
        while not response.endswith(b"\n"):
            if time.monotonic() >= deadline:
                raise TimeoutError("transfer deadline exceeded")
            piece = sock.recv(4096)
            if not piece:
                raise ConnectionError("receiver closed before receipt")
            response += piece
    receipt = json.loads(response.decode())
    if receipt.get("committed") is not True or receipt.get("sha256") != digest:
        raise RuntimeError("receiver rejected artifact part")
    return receipt

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--spec", required=True)
    ap.add_argument("--output", required=True)
    ap.add_argument("--timeout-ms", type=int, default=1800)
    args = ap.parse_args()
    spec = json.loads(Path(args.spec).read_text())
    raw_parts = spec.get("parts") or [{"artifact": spec["artifact"], "bytes": spec["bytes"], "sha256": spec["sha256"]}]
    host, port = spec["receiver"].split(":", 1)
    payloads = []
    for item in raw_parts:
        payload = make_payload(item["artifact"], int(item["bytes"]))
        digest = hashlib.sha256(payload).hexdigest()
        if digest != item["sha256"]:
            raise SystemExit("fixture digest mismatch")
        payloads.append((item, payload))
    aggregate = hashlib.sha256(b"".join(payload for _, payload in payloads)).hexdigest()
    if aggregate != spec["sha256"]:
        raise SystemExit("aggregate fixture digest mismatch")
    started = time.monotonic()
    deadline = started + args.timeout_ms / 1000.0
    receipts = [send_part(host, int(port), item["artifact"], spec["revision"], payload, deadline) for item, payload in payloads]
    elapsed_ms = round((time.monotonic() - started) * 1000, 2)
    result = {"artifact": spec["artifact"], "revision": spec["revision"], "committed": all(x.get("committed") for x in receipts), "sha256": aggregate, "size": sum(len(x[1]) for x in payloads), "parts": receipts, "elapsed_ms": elapsed_ms}
    Path(args.output).write_text(json.dumps(result, sort_keys=True, indent=2) + "\n")
    print(json.dumps(result, sort_keys=True))

if __name__ == "__main__":
    main()

