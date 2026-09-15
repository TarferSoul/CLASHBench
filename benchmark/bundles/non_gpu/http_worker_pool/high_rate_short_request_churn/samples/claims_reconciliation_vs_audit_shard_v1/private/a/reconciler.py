#!/usr/bin/env python3
import hashlib
import json
import os
import signal
import threading
import time
import urllib.request

HOST = os.environ["A_HOST"]
PORT = int(os.environ["A_PORT"])
PRODUCERS = int(os.environ["A_PRODUCERS"])
PROGRESS_FILE = os.environ["A_PROGRESS_FILE"]
stop_event = threading.Event()
write_lock = threading.Lock()
sequence_lock = threading.Lock()
sequence = 0


def stop(_signum, _frame):
    stop_event.set()


def next_id(worker):
    global sequence
    with sequence_lock:
        sequence += 1
        return f"INV-{worker:02d}-{sequence:06d}"


def record(entry):
    with write_lock:
        with open(PROGRESS_FILE, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(entry, sort_keys=True) + "\n")
            handle.flush()


def submit(worker):
    base = f"http://{HOST}:{PORT}/v1/reconcile"
    while not stop_event.is_set():
        claim_id = next_id(worker)
        body = {
            "claim_id": claim_id,
            "member": f"MEM-{worker:02d}",
            "amount_cents": 1000 + (int(claim_id[-3:]) % 9000),
            "revision": "billing-cycle-2026-07",
            "source": "nightly-reconciliation",
        }
        raw = json.dumps(body, sort_keys=True, separators=(",", ":")).encode()
        started = time.monotonic()
        try:
            request = urllib.request.Request(base, data=raw, headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(request, timeout=3.0) as response:
                result = json.load(response)
            if result.get("valid"):
                record({
                    "claim_id": claim_id,
                    "validation_checksum": result.get("validation_checksum"),
                    "payload_checksum": hashlib.sha256(raw).hexdigest(),
                    "worker": worker,
                    "elapsed_ms": round((time.monotonic() - started) * 1000, 2),
                    "finished_at": time.time(),
                })
        except Exception:
            if stop_event.wait(0.01):
                break


def main():
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    threads = [threading.Thread(target=submit, args=(i,), name="reconcile-client", daemon=True) for i in range(PRODUCERS)]
    for thread in threads:
        thread.start()
    while not stop_event.wait(0.2):
        pass
    for thread in threads:
        thread.join(timeout=3)


if __name__ == "__main__":
    main()
