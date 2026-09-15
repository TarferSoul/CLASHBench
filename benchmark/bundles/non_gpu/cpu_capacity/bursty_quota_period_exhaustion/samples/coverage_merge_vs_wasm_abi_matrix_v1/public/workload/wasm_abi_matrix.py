#!/usr/bin/env python3
"""Run deterministic WebAssembly module ABI acceptance checks."""

import argparse
import concurrent.futures
import ctypes
import hashlib
import json
import os
import pathlib
import time


def set_name(name):
    try:
        ctypes.CDLL(None).prctl(15, name.encode()[:15], 0, 0, 0)
    except Exception:
        pass


def atomic_json(path, payload):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + f".tmp.{os.getpid()}")
    temp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    os.replace(temp, path)


def validate_module(payload):
    module_id, exports, rounds, seed = payload
    set_name("wasm-abi-check")
    started = time.perf_counter()
    digest = hashlib.sha256(f"module:{seed}:{module_id}".encode()).digest()
    signature_fold = 0
    for export_id in range(exports):
        value = hashlib.pbkdf2_hmac(
            "sha256", digest, f"abi:{module_id}:{export_id}".encode(), rounds
        )
        digest = hashlib.blake2b(digest + value, digest_size=32).digest()
        signature_fold ^= int.from_bytes(value[:8], "little")
    return {
        "schema": "wasm-abi-verdict-v1",
        "module_id": module_id,
        "export_count": exports,
        "compatible": signature_fold % 17 != 0,
        "signature_fold": signature_fold,
        "content_digest": digest.hex(),
        "elapsed_ms": round((time.perf_counter() - started) * 1000.0, 3),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--job", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--deadline-ms", type=float, default=None)
    args = parser.parse_args()
    job = json.loads(pathlib.Path(args.job).read_text())
    output = pathlib.Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    for old in output.glob("*.json"):
        old.unlink()
    deadline = float(args.deadline_ms if args.deadline_ms is not None else job["max_module_ms"])
    payloads = [
        (module_id, int(job["exports_per_module"]), int(job["validation_rounds"]), int(job["seed"]))
        for module_id in range(int(job["module_count"]))
    ]
    with concurrent.futures.ProcessPoolExecutor(max_workers=int(job["worker_count"])) as executor:
        verdicts = list(executor.map(validate_module, payloads))
    verdicts.sort(key=lambda row: row["module_id"])
    for row in verdicts:
        atomic_json(output / f"module-{row['module_id']:02d}.json", row)
    aggregate = hashlib.sha256()
    for row in verdicts:
        aggregate.update(row["content_digest"].encode())
    misses = sum(float(row["elapsed_ms"]) > deadline for row in verdicts)
    attestation = {
        "schema": "wasm-abi-attestation-v1",
        "module_count": len(verdicts),
        "expected_module_count": int(job["module_count"]),
        "complete": len(verdicts) == int(job["module_count"]),
        "compatible_modules": sum(bool(row["compatible"]) for row in verdicts),
        "deadline_ms": round(deadline, 3),
        "deadline_misses": misses,
        "max_latency_ms": max(float(row["elapsed_ms"]) for row in verdicts),
        "latencies_ms": [float(row["elapsed_ms"]) for row in verdicts],
        "module_digests": [row["content_digest"] for row in verdicts],
        "aggregate_digest": aggregate.hexdigest(),
    }
    atomic_json(output / "attestation.json", attestation)
    print(json.dumps(attestation, sort_keys=True))
    raise SystemExit(0 if attestation["complete"] and misses == 0 else 2)


if __name__ == "__main__":
    main()
