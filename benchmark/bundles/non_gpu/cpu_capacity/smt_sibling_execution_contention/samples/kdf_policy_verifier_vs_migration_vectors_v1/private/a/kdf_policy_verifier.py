#!/usr/bin/env python3
"""Continuously verify deployed PBKDF2 credential-policy vectors."""

import argparse
import hashlib
import json
import os
import pathlib
import random
import signal
import tempfile
import time

running = True


def stop(_signum, _frame):
    global running
    running = False


def atomic_json(path, value):
    path = pathlib.Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    with os.fdopen(fd, "w") as handle:
        json.dump(value, handle, sort_keys=True); handle.write("\n"); handle.flush(); os.fsync(handle.fileno())
    os.replace(temporary, path)


def file_digest(path): return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def merkle(values):
    nodes = [hashlib.sha256(b"leaf:" + value).digest() for value in values]
    while len(nodes) > 1:
        if len(nodes) % 2: nodes.append(nodes[-1])
        nodes = [hashlib.sha256(b"node:" + nodes[index] + nodes[index + 1]).digest() for index in range(0, len(nodes), 2)]
    return nodes[0].hex()


def prepare(root, iterations):
    root.mkdir(parents=True, exist_ok=True)
    atomic_json(root / "policy.json", {"algorithm": "pbkdf2-hmac-sha256", "dklen": 32, "iterations": iterations, "policy_version": "authn-prod-v9"})
    generator = random.Random(0xC0DE5AFE)
    with (root / "policy_vectors.jsonl").open("w") as handle:
        for index in range(12):
            value = {"vector_id": f"policy-{index + 1:02d}", "secret_hex": generator.randbytes(24).hex(), "salt_hex": generator.randbytes(16).hex()}
            handle.write(json.dumps(value, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser(); parser.add_argument("--state-root"); parser.add_argument("--input-root", required=True); parser.add_argument("--artifact-root"); parser.add_argument("--work-factor", type=int, default=105000); parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args(); input_root = pathlib.Path(args.input_root)
    if args.prepare_only: prepare(input_root, args.work_factor); print("POLICY_INPUTS_READY=1 vectors=12"); return
    if not args.state_root or not args.artifact_root: raise SystemExit("--state-root and --artifact-root are required")
    state_root, artifact_root = pathlib.Path(args.state_root), pathlib.Path(args.artifact_root); state_root.mkdir(parents=True, exist_ok=True); artifact_root.mkdir(parents=True, exist_ok=True)
    policy = json.loads((input_root / "policy.json").read_text()); vectors = [json.loads(line) for line in (input_root / "policy_vectors.jsonl").read_text().splitlines() if line]
    ledger = state_root / "unit_ledger.jsonl"; ledger.write_text("")
    signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop); unit = 0
    while running:
        unit += 1; atomic_json(state_root / "status.json", {"pid": os.getpid(), "unit": unit, "phase": "verifying", "affinity": sorted(os.sched_getaffinity(0)), "updated_at": time.time()})
        started = time.perf_counter(); derived = []
        for vector in vectors:
            derived.append(hashlib.pbkdf2_hmac("sha256", bytes.fromhex(vector["secret_hex"]), bytes.fromhex(vector["salt_hex"]), policy["iterations"], dklen=policy["dklen"]))
        if not running: break
        artifact = {"algorithm": policy["algorithm"], "iterations": policy["iterations"], "policy_version": policy["policy_version"], "unit": unit, "vector_count": len(vectors), "merkle_root": merkle(derived), "completed_at": time.time()}
        name = f"policy_attestation_slot_{unit % 4}.json"; target = artifact_root / name; atomic_json(target, artifact)
        entry = {"unit": unit, "artifact": name, "artifact_sha256": file_digest(target), "merkle_root": artifact["merkle_root"], "elapsed_seconds": time.perf_counter() - started, "completed_at": time.time()}
        with ledger.open("a") as handle:
            handle.write(json.dumps(entry, sort_keys=True) + "\n"); handle.flush(); os.fsync(handle.fileno())
        atomic_json(state_root / "status.json", {"pid": os.getpid(), "unit": unit, "phase": "published", "artifact": name, "affinity": sorted(os.sched_getaffinity(0)), "updated_at": time.time()})


if __name__ == "__main__": main()
