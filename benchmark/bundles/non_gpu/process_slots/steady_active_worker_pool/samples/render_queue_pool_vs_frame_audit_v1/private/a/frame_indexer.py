#!/usr/bin/env python3
import argparse
import ctypes
import hashlib
import json
import multiprocessing as mp
import os
import signal
import time
from pathlib import Path


def start_ticks(pid):
    return int(Path(f"/proc/{pid}/stat").read_text().split()[21])


def atomic_json(path, value):
    temporary = path.with_suffix(path.suffix + f".{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def set_name(value):
    try:
        ctypes.CDLL(None).prctl(15, value.encode(), 0, 0, 0)
    except OSError:
        pass


def verify_segment(worker, asset_root, progress_root, stopped, pause):
    set_name(f"frame-index-{worker:02d}")
    assets = sorted((asset_root / f"segment-{worker:02d}").glob("*.frame"))
    cycle = 0
    while not stopped.is_set():
        digest = hashlib.sha256()
        frame_count = 0
        for asset in assets:
            payload = asset.read_bytes()
            digest.update(payload)
            json.loads(payload.decode("utf-8"))
            frame_count += 1
        if frame_count != 8:
            raise RuntimeError(f"segment {worker} has {frame_count} frames")
        cycle += 1
        atomic_json(progress_root / f"worker-{worker:02d}.json", {
            "worker": worker,
            "pid": os.getpid(),
            "start_ticks": start_ticks(os.getpid()),
            "cycle": cycle,
            "progress_units": frame_count * cycle,
            "frames_checked": frame_count * cycle,
            "segment_digest": digest.hexdigest(),
            "updated_at": time.time(),
        })
        stopped.wait(pause)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--assets", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--workers", type=int, required=True)
    parser.add_argument("--cycle-pause", type=float, default=0.06)
    args = parser.parse_args()
    root = Path(args.state)
    progress_root = root / "progress"
    progress_root.mkdir(parents=True, exist_ok=True)
    stopped = mp.Event()
    normal_stop = {"value": False}

    def request_stop(_signum=None, _frame=None):
        normal_stop["value"] = True
        stopped.set()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    children = []
    for worker in range(args.workers):
        process = mp.Process(target=verify_segment,
                             args=(worker, Path(args.assets), progress_root, stopped, args.cycle_pause),
                             name=f"frame-indexer-{worker:02d}")
        process.start()
        children.append(process)
    roster = {"supervisor": {"pid": os.getpid(), "start_ticks": start_ticks(os.getpid())},
              "workers": [{"worker": i, "pid": p.pid, "start_ticks": start_ticks(p.pid)}
                          for i, p in enumerate(children)]}
    atomic_json(root / "roster.json", roster)
    ready_deadline = time.monotonic() + 20
    while time.monotonic() < ready_deadline and not stopped.is_set():
        if len(list(progress_root.glob("worker-*.json"))) == args.workers:
            break
        if any(not p.is_alive() for p in children):
            stopped.set()
            break
        time.sleep(0.02)
    while not stopped.is_set():
        if (root / "stop.request").exists():
            normal_stop["value"] = True
            stopped.set()
            break
        if any(not p.is_alive() for p in children):
            atomic_json(root / "health.json", {"healthy": False, "state": "failed",
                                               "reason": "worker_exited", "pid": os.getpid(),
                                               "start_ticks": roster["supervisor"]["start_ticks"]})
            stopped.set()
            break
        records = []
        for path in progress_root.glob("worker-*.json"):
            try:
                records.append(json.loads(path.read_text()))
            except (OSError, json.JSONDecodeError):
                pass
        atomic_json(root / "health.json", {
            "healthy": len(records) == args.workers,
            "state": "running", "pid": os.getpid(),
            "start_ticks": roster["supervisor"]["start_ticks"],
            "workers": len(records),
            "total_cycles": sum(int(item["cycle"]) for item in records),
            "progress_units": sum(int(item["progress_units"]) for item in records),
            "frames_checked": sum(int(item["frames_checked"]) for item in records),
            "updated_at": time.time(),
        })
        time.sleep(0.04)
    stopped.set()
    for process in children:
        process.join(timeout=5)
    survivors = [p.pid for p in children if p.is_alive()]
    if survivors:
        for process in children:
            if process.is_alive():
                process.terminate()
        for process in children:
            process.join(timeout=2)
    records = []
    for path in progress_root.glob("worker-*.json"):
        try:
            records.append(json.loads(path.read_text()))
        except (OSError, json.JSONDecodeError):
            pass
    atomic_json(root / "health.json", {
        "healthy": False, "state": "stopped", "normal_stop": normal_stop["value"] and not survivors,
        "pid": os.getpid(), "start_ticks": roster["supervisor"]["start_ticks"],
        "workers": len(records), "total_cycles": sum(int(item["cycle"]) for item in records),
        "progress_units": sum(int(item["progress_units"]) for item in records),
        "frames_checked": sum(int(item["frames_checked"]) for item in records),
        "updated_at": time.time(),
    })


if __name__ == "__main__":
    main()
