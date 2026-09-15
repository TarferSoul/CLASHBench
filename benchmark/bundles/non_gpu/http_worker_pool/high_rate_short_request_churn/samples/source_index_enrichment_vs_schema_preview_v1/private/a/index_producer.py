#!/usr/bin/env python3
import fcntl
import itertools
import json
import os
import signal
import sys
import threading
import time
import urllib.error
import urllib.request


ROOT = os.environ["CASE_PRIVATE_ROOT"]
HOST = os.environ.get("A_HOST", "127.0.0.1")
PORT = os.environ.get("A_PORT", "25783")
STOP_FILE = os.environ["A_STOP_FILE"]
PROGRESS_FILE = os.environ["A_PROGRESS_FILE"]
THREADS = int(os.environ.get("A_PRODUCER_THREADS", "8"))
PRIVATE_DOCS_FILE = os.environ.get("PRIVATE_DOCS_FILE", "data/incumbent_docs.json")
URL = f"http://{HOST}:{PORT}/enrich"
stop_event = threading.Event()
progress_lock = threading.Lock()


def load_docs():
    path = os.path.join(ROOT, PRIVATE_DOCS_FILE)
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)["documents"]


def stopped():
    return stop_event.is_set() or os.path.exists(STOP_FILE)


def append_progress(record):
    os.makedirs(os.path.dirname(PROGRESS_FILE), exist_ok=True)
    line = json.dumps(record, sort_keys=True)
    with progress_lock:
        with open(PROGRESS_FILE, "a", encoding="utf-8") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            handle.write(line + "\n")
            handle.flush()
            os.fsync(handle.fileno())
            fcntl.flock(handle, fcntl.LOCK_UN)


def request(doc, worker_id, seq):
    body = json.dumps(doc, sort_keys=True).encode("utf-8")
    req = urllib.request.Request(
        URL,
        data=body,
        headers={
            "Content-Type": "application/json",
            "X-Client-Workload": "incumbent-index",
        },
        method="POST",
    )
    started = time.time()
    with urllib.request.urlopen(req, timeout=3.0) as response:
        payload = json.loads(response.read().decode("utf-8"))
    append_progress({
        "ts": time.time(),
        "worker": worker_id,
        "seq": seq,
        "doc_id": doc.get("doc_id"),
        "status": 200,
        "checksum": payload.get("enrichment_checksum"),
        "elapsed_ms": round((time.time() - started) * 1000, 3),
    })


def worker(worker_id, docs):
    for seq, doc in enumerate(itertools.cycle(docs), start=1):
        if stopped():
            return
        try:
            request(doc, worker_id, seq)
        except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
            append_progress({
                "ts": time.time(),
                "worker": worker_id,
                "seq": seq,
                "doc_id": doc.get("doc_id"),
                "status": "error",
                "error": type(exc).__name__,
            })
            time.sleep(0.05)


def main():
    docs = load_docs()
    os.makedirs(os.path.dirname(PROGRESS_FILE), exist_ok=True)
    threads = [
        threading.Thread(target=worker, args=(idx, docs[idx::THREADS] or docs), daemon=False)
        for idx in range(THREADS)
    ]
    for thread in threads:
        thread.start()
    while not stopped() and any(thread.is_alive() for thread in threads):
        time.sleep(0.1)
    stop_event.set()
    for thread in threads:
        thread.join(timeout=4.0)
    return 0


def term(_signum, _frame):
    stop_event.set()


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, term)
    signal.signal(signal.SIGINT, term)
    raise SystemExit(main())
