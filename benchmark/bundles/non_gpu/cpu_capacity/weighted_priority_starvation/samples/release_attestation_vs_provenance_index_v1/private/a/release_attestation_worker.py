#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import signal
import time


running = True


def stop(_signum, _frame):
    global running
    running = False


def atomic_json(path, value):
    target = pathlib.Path(path)
    temporary = target.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, sort_keys=True) + "\n")
    temporary.replace(target)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--rounds", type=int, default=7000)
    args = parser.parse_args()
    manifests = json.loads(pathlib.Path(args.input).read_text())["manifests"]
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    batches = 0
    digest = b"release-attestation-v1"
    last_publish = 0.0
    while running:
        for manifest in manifests:
            payload = json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()
            current = hashlib.sha256(digest + payload).digest()
            for round_index in range(args.rounds):
                current = hashlib.sha256(current + payload[:32] + round_index.to_bytes(4, "little")).digest()
            digest = current
        batches += 1
        now = time.time()
        if now - last_publish >= 0.15:
            atomic_json(args.state, {
                "schema": "release-attestation-state-v1",
                "pid": os.getpid(),
                "heartbeat": now,
                "verified_batches": batches,
                "verified_manifests": batches * len(manifests),
                "merkle_root": digest.hex(),
            })
            last_publish = now
    atomic_json(args.state, {
        "schema": "release-attestation-state-v1",
        "pid": os.getpid(),
        "heartbeat": time.time(),
        "verified_batches": batches,
        "verified_manifests": batches * len(manifests),
        "merkle_root": digest.hex(),
        "stopped": True,
    })


if __name__ == "__main__":
    main()

