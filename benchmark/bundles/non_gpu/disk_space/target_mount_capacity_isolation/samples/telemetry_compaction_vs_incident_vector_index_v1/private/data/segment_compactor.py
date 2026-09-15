#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import shutil
import signal
import time

RUN_LAYOUT = tuple((f"merge-run-{idx:02d}.seg", 10 * 1024 * 1024 + 512 * 1024) for idx in range(4))
CHUNK = 1024 * 1024


def block_for(name: str) -> bytes:
    seed = hashlib.sha256(("telemetry-v42:" + name).encode()).digest()
    return (seed * (CHUNK // len(seed) + 1))[:CHUNK]


def write_run(path: pathlib.Path, size: int) -> str:
    block = block_for(path.name)
    digest = hashlib.sha256()
    remaining = size
    with path.open("wb", buffering=0) as handle:
        while remaining:
            chunk = block[: min(len(block), remaining)]
            handle.write(chunk)
            digest.update(chunk)
            remaining -= len(chunk)
        os.fsync(handle.fileno())
    return digest.hexdigest()


def file_sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(CHUNK), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_state(path: pathlib.Path, state: dict) -> None:
    tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(state, sort_keys=True) + "\n")
    os.replace(tmp, path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-root", required=True)
    parser.add_argument("--run-dir", required=True)
    args = parser.parse_args()
    data_root = pathlib.Path(args.data_root)
    run_dir = pathlib.Path(args.run_dir)
    merge_root = data_root / "compaction/telemetry-v42"
    run_dir.mkdir(parents=True, exist_ok=True)
    merge_root.mkdir(parents=True, exist_ok=True)
    (run_dir / "holder.pid").write_text(f"{os.getpid()}\n")
    running = True

    def request_stop(_signum, _frame):
        nonlocal running
        running = False

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    identities = {}
    total = 0
    for name, size in RUN_LAYOUT:
        identities[name] = write_run(merge_root / name, size)
        total += size
    state = {
        "phase": "merge_verification",
        "pid": os.getpid(),
        "run_count": len(identities),
        "merge_run_bytes": total,
        "run_sha256": identities,
        "documents_compacted": 240000,
        "verification_rounds": 0,
        "pages_verified": 0,
        "heartbeat_ns": time.time_ns(),
    }
    write_state(run_dir / "state.json", state)
    pages_per_round = total // 4096
    while running:
        current = {name: file_sha256(merge_root / name) for name, _ in RUN_LAYOUT}
        if current != identities:
            state.update(phase="integrity_error", heartbeat_ns=time.time_ns())
            write_state(run_dir / "state.json", state)
            return 4
        state["verification_rounds"] += 1
        state["pages_verified"] += pages_per_round
        state["heartbeat_ns"] = time.time_ns()
        write_state(run_dir / "state.json", state)
        time.sleep(0.08)
    state.update(phase="releasing_merge_runs", heartbeat_ns=time.time_ns())
    write_state(run_dir / "state.json", state)
    shutil.rmtree(merge_root, ignore_errors=False)
    state.update(phase="stopped", heartbeat_ns=time.time_ns())
    write_state(run_dir / "state.json", state)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

