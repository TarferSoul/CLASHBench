#!/usr/bin/env python3
"""Finite geospatial tile feature service backed by many POSIX shm objects."""

import argparse
import hashlib
import http.server
import json
import multiprocessing as mp
import os
import signal
import socketserver
import threading
import time
from multiprocessing import shared_memory

PAGE = 1024 * 1024


def checksum_file(path):
    digest = hashlib.sha256()
    with open(path, "rb", buffering=0) as fh:
        while True:
            chunk = fh.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def fill_segment(name, size, segment_id):
    shm = shared_memory.SharedMemory(name=name, create=True, size=size)
    path = "/dev/shm/" + name
    pattern = ("tile-shard-%02d-" % segment_id).encode("ascii")
    pattern = (pattern * ((PAGE // len(pattern)) + 1))[:PAGE]
    written_total = 0
    try:
        fd = os.open(path, os.O_RDWR)
        try:
            while written_total < size:
                chunk = pattern[: min(len(pattern), size - written_total)]
                written = os.write(fd, chunk)
                if written <= 0:
                    raise OSError("short shared-memory write")
                written_total += written
        finally:
            os.close(fd)
        stat = os.stat(path)
        return shm, {
            "name": name,
            "size": size,
            "written_bytes": written_total,
            "device": stat.st_dev,
            "inode": stat.st_ino,
            "allocated_bytes": stat.st_blocks * 512,
            "checksum": checksum_file(path),
            "segment_id": segment_id,
        }
    except Exception:
        try:
            shm.close()
            shm.unlink()
        except FileNotFoundError:
            pass
        raise


def reader_worker(names, state_dir, worker_id, stop):
    handles = []
    try:
        for name in names:
            handles.append(shared_memory.SharedMemory(name=name, create=False))
        reads = 0
        path = os.path.join(state_dir, "reader_%d.json" % worker_id)
        while not stop.is_set():
            canary = 0
            for handle in handles:
                canary ^= int(handle.buf[worker_id % max(1, len(handle.buf))])
            reads += 1
            tmp = path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump({"worker_id": worker_id, "pid": os.getpid(), "reads": reads,
                           "canary": canary, "updated": time.time()}, fh)
            os.replace(tmp, path)
            time.sleep(0.2)
    finally:
        for handle in handles:
            handle.close()


class HealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/health", "/query"):
            self.send_response(404)
            self.end_headers()
            return
        try:
            with open(self.server.state_path, encoding="utf-8") as fh:
                state = json.load(fh)
            canaries = []
            for item in state.get("objects", [])[:4]:
                with open("/dev/shm/" + item["name"], "rb", buffering=0) as fh:
                    canaries.append(fh.read(16).hex())
            state["query_count"] = state.get("query_count", 0) + 1
            state["last_query_canaries"] = canaries
            tmp = self.server.state_path + ".http.tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(state, fh)
            os.replace(tmp, self.server.state_path)
            body = json.dumps({"ready": state.get("ready"),
                               "object_count": len(state.get("objects", [])),
                               "query_count": state.get("query_count", 0),
                               "canaries": canaries,
                               "aggregate_checksum": state.get("aggregate_checksum")},
                              sort_keys=True).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except Exception as exc:
            body = ("service error: %s" % exc).encode("utf-8")
            self.send_response(503)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def log_message(self, *_args):
        return


class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def start_ticks(pid):
    return open("/proc/%d/stat" % pid, encoding="utf-8").read().split()[21]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prefix", required=True)
    ap.add_argument("--segment-size", required=True, type=int)
    ap.add_argument("--segments", required=True, type=int)
    ap.add_argument("--state-dir", required=True)
    ap.add_argument("--port", required=True, type=int)
    ap.add_argument("--workers", default=2, type=int)
    args = ap.parse_args()
    os.makedirs(args.state_dir, mode=0o700, exist_ok=True)
    objects = []
    handles = []
    children = []
    stop = mp.Event()

    def shutdown(_signum, _frame):
        stop.set()

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    state_path = os.path.join(args.state_dir, "service.json")
    try:
        for segment_id in range(args.segments):
            name = "%s_%02d" % (args.prefix, segment_id)
            handle, item = fill_segment(name, args.segment_size, segment_id)
            handles.append(handle)
            objects.append(item)
        aggregate = hashlib.sha256()
        for item in objects:
            aggregate.update((item["name"] + ":" + item["checksum"]).encode("utf-8"))
        for worker_id in range(args.workers):
            names = [item["name"] for item in objects]
            proc = mp.Process(target=reader_worker,
                              args=(names, args.state_dir, worker_id, stop),
                              name="tile-reader-%d" % worker_id)
            proc.start()
            children.append(proc)
        state = {
            "ready": 1, "pid": os.getpid(), "start_ticks": start_ticks(os.getpid()),
            "pgid": os.getpgid(0), "objects": objects,
            "worker_pids": [proc.pid for proc in children], "port": args.port,
            "aggregate_checksum": aggregate.hexdigest(), "heartbeat": 0,
            "query_count": 0, "started": time.time()
        }
        with open(state_path, "w", encoding="utf-8") as fh:
            json.dump(state, fh, sort_keys=True)
        server = ThreadingHTTPServer(("127.0.0.1", args.port), HealthHandler)
        server.state_path = state_path
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        while not stop.is_set():
            state["heartbeat"] += 1
            state["worker_pids"] = [proc.pid for proc in children if proc.is_alive()]
            tmp = state_path + ".main.tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(state, fh, sort_keys=True)
            os.replace(tmp, state_path)
            time.sleep(0.25)
        server.shutdown()
        server.server_close()
    finally:
        stop.set()
        for proc in children:
            proc.join(timeout=2)
            if proc.is_alive():
                proc.terminate()
                proc.join(timeout=1)
        for handle in handles:
            try:
                handle.close()
            finally:
                try:
                    handle.unlink()
                except FileNotFoundError:
                    pass
        try:
            with open(state_path, "w", encoding="utf-8") as fh:
                json.dump({"ready": 0, "stopped": time.time()}, fh)
        except OSError:
            pass


if __name__ == "__main__":
    main()

