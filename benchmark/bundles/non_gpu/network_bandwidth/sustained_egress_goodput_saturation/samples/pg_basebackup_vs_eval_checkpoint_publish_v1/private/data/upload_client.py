#!/usr/bin/env python3
"""Publish a declared artifact set and write receiver-issued receipts."""
import argparse
import hashlib
import json
import socket
import time
from pathlib import Path


def deterministic_bytes(label, size):
    output = bytearray()
    counter = 0
    while len(output) < size:
        output.extend(hashlib.sha256(f"{label}:{counter}".encode()).digest())
        counter += 1
    return bytes(output[:size])


def send_part(host, port, spec, part, deadline):
    payload = deterministic_bytes(f"{spec['artifact']}:{part['name']}", int(part["size"]))
    digest = hashlib.sha256(payload).hexdigest()
    if digest != part["sha256"]:
        raise ValueError("public fixture digest mismatch")
    timeout = max(0.1, deadline - time.monotonic())
    header = {
        "stream": "task",
        "kind": part["kind"],
        "name": part["name"],
        "revision": spec["revision"],
        "size": len(payload),
        "sha256": digest,
    }
    with socket.create_connection((host, port), timeout=timeout) as connection:
        connection.settimeout(timeout)
        connection.sendall((json.dumps(header, sort_keys=True) + "\n").encode() + payload)
        response = b""
        while not response.endswith(b"\n"):
            if time.monotonic() >= deadline:
                raise TimeoutError("publication deadline exceeded")
            piece = connection.recv(4096)
            if not piece:
                raise ConnectionError("receiver closed before receipt")
            response += piece
    receipt = json.loads(response.decode())
    if receipt.get("committed") is not True or receipt.get("sha256") != digest:
        raise RuntimeError("receiver rejected artifact part")
    return receipt, payload


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--spec", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--timeout-ms", type=int)
    args = parser.parse_args()
    spec = json.loads(Path(args.spec).read_text())
    host, port_text = spec["gateway"].split(":", 1)
    timeout_ms = args.timeout_ms or int(spec["deadline_ms"])
    started = time.monotonic()
    deadline = started + timeout_ms / 1000.0
    receipts = []
    payloads = []
    error = None
    try:
        for part in spec["parts"]:
            receipt, payload = send_part(host, int(port_text), spec, part, deadline)
            receipts.append(receipt)
            payloads.append(payload)
    except Exception as exc:
        error = type(exc).__name__
    elapsed_ms = round((time.monotonic() - started) * 1000, 3)
    aggregate = hashlib.sha256(b"".join(payloads)).hexdigest() if len(payloads) == len(spec["parts"]) else None
    result = {
        "artifact": spec["artifact"],
        "revision": spec["revision"],
        "gateway": spec["gateway"],
        "committed": error is None and len(receipts) == len(spec["parts"]) and aggregate == spec["aggregate_sha256"],
        "aggregate_sha256": aggregate,
        "size": sum(int(item.get("size", 0)) for item in receipts),
        "parts": receipts,
        "elapsed_ms": elapsed_ms,
        "deadline_ms": int(spec["deadline_ms"]),
        "error": error,
    }
    Path(args.output).write_text(json.dumps(result, sort_keys=True, indent=2) + "\n")
    print(json.dumps(result, sort_keys=True))
    raise SystemExit(0 if result["committed"] else 4)


if __name__ == "__main__":
    main()

