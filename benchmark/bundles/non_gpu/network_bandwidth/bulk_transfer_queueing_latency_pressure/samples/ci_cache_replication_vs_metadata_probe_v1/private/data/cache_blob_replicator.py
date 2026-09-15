#!/usr/bin/env python3
import argparse
import hashlib
import http.client
import json
import pathlib
import tempfile
import threading
import time
import urllib.parse


def atomic_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=path.name, dir=str(path.parent))
    with open(fd, "w") as handle:
        json.dump(value, handle, sort_keys=True, indent=2)
        handle.write("\n")
    pathlib.Path(tmp_name).replace(path)


def make_blob(seed, sequence, size):
    pieces = []
    produced = 0
    block = 0
    while produced < size:
        material = hashlib.sha256(f"{seed}:blob:{sequence}:{block}".encode()).digest()
        take = min(len(material), size - produced)
        pieces.append(material[:take])
        produced += take
        block += 1
    return b"".join(pieces)


def post_blob(base_url, digest, body, timeout):
    parsed = urllib.parse.urlparse(base_url)
    conn = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=timeout)
    path = f"/v1/cache/blobs/{digest}"
    started = time.perf_counter()
    try:
        conn.request(
            "POST",
            path,
            body=body,
            headers={
                "Content-Type": "application/octet-stream",
                "Content-Length": str(len(body)),
                "User-Agent": "ci-cache-blob-replicator/1",
            },
        )
        resp = conn.getresponse()
        payload = resp.read()
        elapsed = time.perf_counter() - started
        if resp.status != 200:
            raise RuntimeError(f"upload status={resp.status} body={payload[:200]!r}")
        data = json.loads(payload.decode())
        if data.get("digest") != digest or data.get("committed") is not True:
            raise RuntimeError(f"unexpected commit response: {data}")
        return elapsed
    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--blob-bytes", type=int, required=True)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--seed", required=True)
    parser.add_argument("--state-path", required=True)
    parser.add_argument("--stop-file", required=True)
    parser.add_argument("--timeout", type=float, default=20.0)
    args = parser.parse_args()

    lock = threading.Lock()
    sequence = {"value": 0}
    state = {
        "started_at": time.time(),
        "workers": int(args.workers),
        "committed_count": 0,
        "committed_bytes": 0,
        "last_digest": "",
        "last_elapsed_seconds": None,
        "errors": [],
    }
    atomic_json(args.state_path, state)
    stop_file = pathlib.Path(args.stop_file)

    def next_sequence():
        with lock:
            value = sequence["value"]
            sequence["value"] += 1
            return value

    def update_success(digest, size, elapsed):
        with lock:
            state["committed_count"] += 1
            state["committed_bytes"] += size
            state["last_digest"] = digest
            state["last_elapsed_seconds"] = elapsed
            state["last_committed_at"] = time.time()
            atomic_json(args.state_path, state)

    def update_error(exc):
        with lock:
            state["errors"].append(f"{type(exc).__name__}: {exc}")
            state["errors"] = state["errors"][-20:]
            atomic_json(args.state_path, state)

    def worker(worker_id):
        while not stop_file.exists():
            current = next_sequence()
            body = make_blob(args.seed, current, args.blob_bytes)
            digest = hashlib.sha256(body).hexdigest()
            try:
                elapsed = post_blob(args.base_url, digest, body, args.timeout)
                update_success(digest, len(body), elapsed)
            except Exception as exc:
                update_error(exc)
                time.sleep(0.1 + worker_id * 0.01)

    threads = [
        threading.Thread(target=worker, args=(idx,), daemon=True)
        for idx in range(max(1, int(args.workers)))
    ]
    for thread in threads:
        thread.start()
    try:
        while not stop_file.exists():
            time.sleep(0.2)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
