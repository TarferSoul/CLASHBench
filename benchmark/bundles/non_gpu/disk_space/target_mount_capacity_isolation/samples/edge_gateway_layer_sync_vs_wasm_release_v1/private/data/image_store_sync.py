#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import shutil
import signal
import time

LAYER_LAYOUT = (
    ("sha256-2a9f14c8d0-base.layer", 17 * 1024 * 1024),
    ("sha256-7cb1369aa1-runtime.layer", 17 * 1024 * 1024),
    ("sha256-c581e42b73-policy.layer", 17 * 1024 * 1024),
)
CHUNK = 1024 * 1024


def block_for(name: str) -> bytes:
    seed = hashlib.sha256(("edge-runtime:" + name).encode()).digest()
    return (seed * (CHUNK // len(seed) + 1))[:CHUNK]


def write_layer(path: pathlib.Path, size: int) -> str:
    digest = hashlib.sha256()
    block = block_for(path.name)
    remaining = size
    with path.open("wb", buffering=0) as handle:
        while remaining:
            part = block[: min(len(block), remaining)]
            handle.write(part)
            digest.update(part)
            remaining -= len(part)
        os.fsync(handle.fileno())
    return digest.hexdigest()


def file_sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_state(path: pathlib.Path, payload: dict) -> None:
    tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(payload, sort_keys=True) + "\n")
    os.replace(tmp, path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--store", required=True)
    parser.add_argument("--run-dir", required=True)
    args = parser.parse_args()
    store = pathlib.Path(args.store)
    run_dir = pathlib.Path(args.run_dir)
    layer_root = store / "buildkit/snapshots/edge-base-refresh"
    run_dir.mkdir(parents=True, exist_ok=True)
    layer_root.mkdir(parents=True, exist_ok=True)
    (run_dir / "holder.pid").write_text(f"{os.getpid()}\n")

    running = True

    def request_stop(_signum, _frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    identities = {}
    total = 0
    for name, size in LAYER_LAYOUT:
        path = layer_root / name
        identities[name] = write_layer(path, size)
        total += size

    state = {
        "phase": "verifying",
        "pid": os.getpid(),
        "layer_bytes": total,
        "layer_count": len(identities),
        "layer_sha256": identities,
        "verification_passes": 0,
        "verified_bytes": 0,
        "heartbeat_ns": time.time_ns(),
    }
    atomic_state(run_dir / "state.json", state)
    while running:
        current = {name: file_sha256(layer_root / name) for name, _ in LAYER_LAYOUT}
        if current != identities:
            state.update(phase="integrity_error", heartbeat_ns=time.time_ns())
            atomic_state(run_dir / "state.json", state)
            return 4
        state["verification_passes"] += 1
        state["verified_bytes"] += total
        state["heartbeat_ns"] = time.time_ns()
        atomic_state(run_dir / "state.json", state)
        time.sleep(0.08)

    state.update(phase="releasing", heartbeat_ns=time.time_ns())
    atomic_state(run_dir / "state.json", state)
    shutil.rmtree(layer_root, ignore_errors=False)
    state.update(phase="stopped", heartbeat_ns=time.time_ns())
    atomic_state(run_dir / "state.json", state)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
