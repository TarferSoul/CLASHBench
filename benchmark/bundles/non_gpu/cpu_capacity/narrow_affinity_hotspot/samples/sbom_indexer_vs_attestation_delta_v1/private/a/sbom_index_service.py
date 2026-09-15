#!/usr/bin/env python3
"""Continuous software-supply-chain dependency index canonicalizer."""

import argparse
import hashlib
import json
import os
import pathlib
import signal
import time

STOP = False


def stop(_signum, _frame):
    global STOP
    STOP = True


def atomic_json(path, value):
    path = pathlib.Path(path)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    os.replace(tmp, path)


def start_ticks():
    return pathlib.Path(f"/proc/{os.getpid()}/stat").read_text().split()[21]


def graph():
    licenses = ["Apache-2.0", "MIT", "BSD-3-Clause", "MPL-2.0"]
    return [
        {
            "name": f"pkg-{index:04d}",
            "version": f"{1 + index % 9}.{index % 17}.{index % 23}",
            "license": licenses[index % len(licenses)],
            "dependencies": [f"pkg-{(index * 7 + step * 13) % 768:04d}" for step in range(5)],
        }
        for index in range(768)
    ]


def index_epoch(records, seed, epoch):
    leaves = []
    for shard in range(12):
        for record in records[shard::12]:
            encoded = json.dumps(record, sort_keys=True, separators=(",", ":")).encode()
            digest = hashlib.sha256(seed + encoded + epoch.to_bytes(4, "little")).digest()
            for round_index in range(8):
                digest = hashlib.sha256(digest + encoded + round_index.to_bytes(1, "little")).digest()
            leaves.append(digest)
    leaves.sort()
    while len(leaves) > 1:
        if len(leaves) % 2:
            leaves.append(leaves[-1])
        leaves = [hashlib.sha256(leaves[i] + leaves[i + 1]).digest() for i in range(0, len(leaves), 2)]
    return leaves[0]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-root", required=True)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    root = pathlib.Path(args.state_root)
    root.mkdir(parents=True, exist_ok=True)
    ledger = root / "epochs.jsonl"
    ledger.write_text("")
    records = graph()
    seed = hashlib.sha256(b"sbom-index-seed").digest()
    epoch = 0
    canonicalized = 0
    state = {}
    while not STOP:
        epoch += 1
        seed = index_epoch(records, seed, epoch)
        canonicalized += len(records)
        state = {
            "schema": "sbom-index-state-v1", "pid": os.getpid(), "pgid": os.getpgrp(),
            "start_ticks": start_ticks(), "affinity": sorted(os.sched_getaffinity(0)),
            "epoch": epoch, "canonicalized_records": canonicalized,
            "merkle_root": seed.hex(), "phase": "canonicalize_and_merge",
            "updated_at": time.time(),
        }
        atomic_json(root / "state.json", state)
        with ledger.open("a") as stream:
            stream.write(json.dumps(state, sort_keys=True) + "\n")
    state["phase"] = "stopped"
    state["updated_at"] = time.time()
    atomic_json(root / "state.json", state)


if __name__ == "__main__":
    main()
