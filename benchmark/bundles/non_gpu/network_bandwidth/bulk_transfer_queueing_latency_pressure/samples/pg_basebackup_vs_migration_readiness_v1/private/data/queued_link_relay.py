#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import queue
import signal
import socket
import threading
import time


def atomic_json(path, payload):
    path = pathlib.Path(path)
    tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    tmp.replace(path)


class SharedFifo:
    def __init__(self, rate_bps, queue_limit, stats_path):
        self.rate_bps = float(rate_bps)
        self.queue_limit = int(queue_limit)
        self.stats_path = pathlib.Path(stats_path)
        self.cond = threading.Condition()
        self.items = queue.Queue()
        self.queued_bytes = 0
        self.max_queued_bytes = 0
        self.service_bytes = 0
        self.client_bytes = 0
        self.delivered_chunks = 0
        self.last_sojourn_ms = 0.0
        self.max_sojourn_ms = 0.0
        self.active_connections = 0
        self.accepted_connections = 0
        self.shutdown = False
        self.started_at = time.time()

    def snapshot(self):
        elapsed = max(time.time() - self.started_at, 0.001)
        return {
            "schema": "queued-tcp-link-stats-v1",
            "pid": os.getpid(),
            "started_at": self.started_at,
            "updated_at": time.time(),
            "rate_bytes_per_second": self.rate_bps,
            "queue_limit_bytes": self.queue_limit,
            "queued_bytes": self.queued_bytes,
            "max_queued_bytes": self.max_queued_bytes,
            "service_bytes": self.service_bytes,
            "client_bytes": self.client_bytes,
            "delivered_chunks": self.delivered_chunks,
            "last_sojourn_ms": self.last_sojourn_ms,
            "max_sojourn_ms": self.max_sojourn_ms,
            "active_connections": self.active_connections,
            "accepted_connections": self.accepted_connections,
            "mean_service_bytes_per_second": self.service_bytes / elapsed,
        }

    def write_stats(self):
        self.stats_path.parent.mkdir(parents=True, exist_ok=True)
        with self.cond:
            payload = self.snapshot()
        atomic_json(self.stats_path, payload)

    def enqueue(self, backend, data):
        if not data:
            return
        offset = 0
        while offset < len(data):
            part = data[offset : offset + self.queue_limit]
            offset += len(part)
            with self.cond:
                while not self.shutdown and self.queued_bytes + len(part) > self.queue_limit:
                    self.cond.wait(timeout=0.2)
                if self.shutdown:
                    return
                self.items.put((backend, part, time.time()))
                self.queued_bytes += len(part)
                self.client_bytes += len(part)
                self.max_queued_bytes = max(self.max_queued_bytes, self.queued_bytes)
                self.cond.notify_all()

    def get_item(self):
        while not self.shutdown:
            try:
                return self.items.get(timeout=0.2)
            except queue.Empty:
                continue
        return None

    def mark_sent(self, size, enqueued_at):
        with self.cond:
            self.queued_bytes = max(0, self.queued_bytes - size)
            self.service_bytes += size
            self.delivered_chunks += 1
            sojourn = max(time.time() - enqueued_at, 0.0) * 1000.0
            self.last_sojourn_ms = sojourn
            self.max_sojourn_ms = max(self.max_sojourn_ms, sojourn)
            self.cond.notify_all()


def copy_response(backend, client, stats):
    try:
        while True:
            data = backend.recv(16384)
            if not data:
                break
            client.sendall(data)
    except OSError:
        pass
    finally:
        for sock in (backend, client):
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                sock.close()
            except OSError:
                pass
        with stats.cond:
            stats.active_connections = max(0, stats.active_connections - 1)
            stats.cond.notify_all()


def handle_client(client, backend_host, backend_port, chunk_bytes, stats):
    try:
        backend = socket.create_connection((backend_host, backend_port), timeout=5.0)
        backend.settimeout(None)
    except OSError:
        client.close()
        return
    with stats.cond:
        stats.active_connections += 1
        stats.accepted_connections += 1
        stats.cond.notify_all()
    threading.Thread(target=copy_response, args=(backend, client, stats), daemon=True).start()
    try:
        while True:
            data = client.recv(chunk_bytes)
            if not data:
                break
            stats.enqueue(backend, data)
    except OSError:
        pass
    finally:
        try:
            backend.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def service_loop(stats):
    while not stats.shutdown:
        item = stats.get_item()
        if item is None:
            continue
        backend, data, enqueued_at = item
        try:
            backend.sendall(data)
        except OSError:
            pass
        stats.mark_sent(len(data), enqueued_at)
        delay = len(data) / stats.rate_bps
        if delay > 0:
            time.sleep(delay)


def stats_loop(stats):
    while not stats.shutdown:
        stats.write_stats()
        time.sleep(0.1)
    stats.write_stats()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--backend-host", default="127.0.0.1")
    parser.add_argument("--backend-port", type=int, required=True)
    parser.add_argument("--rate-bytes-per-second", type=int, required=True)
    parser.add_argument("--queue-limit-bytes", type=int, required=True)
    parser.add_argument("--chunk-bytes", type=int, default=4096)
    parser.add_argument("--stats-path", required=True)
    args = parser.parse_args()

    stats = SharedFifo(args.rate_bytes_per_second, args.queue_limit_bytes, args.stats_path)

    def terminate(signum, frame):
        with stats.cond:
            stats.shutdown = True
            stats.cond.notify_all()

    signal.signal(signal.SIGTERM, terminate)
    threading.Thread(target=service_loop, args=(stats,), daemon=True).start()
    threading.Thread(target=stats_loop, args=(stats,), daemon=True).start()

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((args.listen_host, args.listen_port))
    listener.listen(128)
    listener.settimeout(0.5)
    try:
        while not stats.shutdown:
            try:
                client, _ = listener.accept()
            except socket.timeout:
                continue
            client.settimeout(None)
            threading.Thread(
                target=handle_client,
                args=(client, args.backend_host, args.backend_port, args.chunk_bytes, stats),
                daemon=True,
            ).start()
    finally:
        listener.close()
        with stats.cond:
            stats.shutdown = True
            stats.cond.notify_all()
        stats.write_stats()


if __name__ == "__main__":
    main()
