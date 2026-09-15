#!/usr/bin/env python3
import argparse
import json
import os
import signal
import threading
import time
import urllib.parse
import urllib.request


def call(url):
    with urllib.request.urlopen(url, timeout=8) as response:
        return json.loads(response.read().decode())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--endpoint", required=True)
    ap.add_argument("--pool", type=int, required=True)
    ap.add_argument("--wave-size", type=int, required=True)
    ap.add_argument("--duration-ms", type=int, required=True)
    ap.add_argument("--period-ms", type=int, required=True)
    ap.add_argument("--units", required=True)
    ap.add_argument("--context", required=True)
    ap.add_argument("--runtime", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    os.makedirs(args.runtime, exist_ok=True)
    os.makedirs(args.output, exist_ok=True)
    stop = threading.Event()
    with open(os.path.join(args.runtime, "scheduler.pid"), "w") as fh:
        json.dump({"pid": os.getpid(), "start_ns": time.time_ns()}, fh)
    units = args.units.split(",")
    wave = 0
    next_start = time.monotonic()

    def handle(_signum, _frame):
        stop.set()

    signal.signal(signal.SIGTERM, handle)
    signal.signal(signal.SIGINT, handle)
    while not stop.is_set():
        delay = next_start - time.monotonic()
        if delay > 0:
            stop.wait(delay)
            if stop.is_set():
                break
        wave += 1
        revision = f"{args.context}-revision-{wave:04d}"
        batch_id = f"incumbent-{args.context}-wave-{wave:04d}"
        print(json.dumps({"kind": "wave_start", "wave": wave, "batch_id": batch_id, "revision": revision, "wall_ns": time.time_ns()}), flush=True)
        results = [None] * args.wave_size

        def one(index):
            unit = units[index % len(units)]
            query = urllib.parse.urlencode({
                "owner": "a", "request_id": f"a-{args.context}-w{wave:04d}-u{index:02d}",
                "batch_id": batch_id, "unit": unit, "revision": revision,
                "duration_ms": args.duration_ms,
            })
            try:
                results[index] = call(args.endpoint + "?" + query)
            except Exception as exc:
                results[index] = {"ok": False, "error": repr(exc)}

        threads = [threading.Thread(target=one, args=(i,)) for i in range(args.wave_size)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        good = [item for item in results if item and item.get("ok") is True]
        if len(good) == args.wave_size:
            record = {
                "wave": wave, "batch_id": batch_id, "revision": revision,
                "context": args.context, "request_count": len(good),
                "receipts": [{"request_id": x["request_id"], "unit": x["unit"], "response_hash": x["response_hash"]} for x in good],
                "completed_ns": time.time_ns(),
            }
            path = os.path.join(args.output, f"revision_{wave:04d}.json")
            temp = path + ".tmp"
            with open(temp, "w") as fh:
                json.dump(record, fh, sort_keys=True)
            os.replace(temp, path)
            with open(os.path.join(args.output, "state.json.tmp"), "w") as fh:
                json.dump({"last_completed_wave": wave, "last_revision": revision, "useful_records": wave}, fh)
            os.replace(os.path.join(args.output, "state.json.tmp"), os.path.join(args.output, "state.json"))
            print(json.dumps({"kind": "wave_complete", "wave": wave, "batch_id": batch_id, "revision": revision, "count": len(good), "wall_ns": time.time_ns()}), flush=True)
        else:
            print(json.dumps({"kind": "wave_failed", "wave": wave, "good": len(good), "expected": args.wave_size, "wall_ns": time.time_ns()}), flush=True)
        next_start += args.period_ms / 1000.0
    print(json.dumps({"kind": "scheduler_stopped", "wave": wave, "wall_ns": time.time_ns()}), flush=True)


if __name__ == "__main__":
    main()
