#!/usr/bin/env python3
import argparse
import json
import math
import os
import signal
import socket
import stat
import threading
import time
from pathlib import Path


BUCKETS = [50, 100, 200, 500, 1000]


def parse_statsd(line):
    line = line.strip()
    if not line or line.startswith("#"):
        return None
    if ":" not in line or "|" not in line:
        raise ValueError(f"invalid statsd sample: {line!r}")
    name, rest = line.split(":", 1)
    value_text, kind = rest.split("|", 1)
    kind = kind.split("|", 1)[0]
    if not name.startswith("llm."):
        raise ValueError(f"unexpected namespace: {name}")
    return name, float(value_text), kind, line


def write_json_atomic(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f"{path.name}.tmp.{os.getpid()}")
    with tmp.open("w", encoding="utf-8") as fh:
        json.dump(data, fh, sort_keys=True, indent=2)
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())
    tmp.replace(path)


def append_jsonl(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(data, sort_keys=True) + "\n")
        fh.flush()
        os.fsync(fh.fileno())


def bucket_for(value):
    for bucket in BUCKETS:
        if value <= bucket:
            return bucket
    return BUCKETS[-1]


class StatsDRelay:
    def __init__(self, socket_path, state_dir, pid_file, flush_interval):
        self.socket_path = Path(socket_path)
        self.state_dir = Path(state_dir)
        self.pid_file = Path(pid_file)
        self.flush_interval = flush_interval
        self.stop_event = threading.Event()
        self.sock = None
        self.socket_node = None
        self.total_packets = 0
        self.rejected_packets = 0
        self.flush_count = 0
        self.counters = {}
        self.gauges = {}
        self.latencies = []
        self.metric_names = set()
        self.started_at = time.time()
        self.last_packet_at = None
        self.last_error = ""

    @property
    def state_path(self):
        return self.state_dir / "state.json"

    @property
    def rollup_path(self):
        return self.state_dir / "rollups.jsonl"

    def bind_socket(self):
        self.socket_path.parent.mkdir(parents=True, exist_ok=True)
        if self.socket_path.exists():
            if stat.S_ISSOCK(self.socket_path.stat().st_mode):
                self.socket_path.unlink()
            else:
                raise RuntimeError(f"{self.socket_path} exists and is not a socket")
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
        self.sock.bind(str(self.socket_path))
        os.chmod(self.socket_path, 0o660)
        self.sock.settimeout(0.1)
        st = self.socket_path.stat()
        self.socket_node = {"dev": st.st_dev, "inode": st.st_ino}

    def write_pid(self):
        self.pid_file.parent.mkdir(parents=True, exist_ok=True)
        self.pid_file.write_text(str(os.getpid()) + "\n", encoding="utf-8")

    def handle_signal(self, _signum, _frame):
        self.stop_event.set()

    def update_metric(self, name, value, kind):
        self.metric_names.add(name)
        if kind == "c":
            self.counters[name] = self.counters.get(name, 0.0) + value
        elif kind == "g":
            self.gauges[name] = value
        elif kind == "ms":
            self.latencies.append(value)
            if len(self.latencies) > 512:
                self.latencies = self.latencies[-512:]

    def producer_loop(self):
        sequence = 0
        while not self.stop_event.is_set():
            sequence += 1
            latency = 35 + (sequence * 17) % 420
            queue_depth = sequence % 7
            burst = [
                "llm.requests:1|c",
                f"llm.tokens:{64 + (sequence % 5) * 16}|c",
                f"llm.request_latency_ms:{latency}|ms",
                f"llm.queue_depth:{queue_depth}|g",
            ]
            sender = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
            try:
                for line in burst:
                    sender.sendto(line.encode("utf-8"), str(self.socket_path))
            except OSError as exc:
                self.last_error = str(exc)
            finally:
                sender.close()
            self.stop_event.wait(0.08)

    def current_summary(self):
        latencies = list(self.latencies)
        buckets = {str(bucket): 0 for bucket in BUCKETS}
        for value in latencies:
            buckets[str(bucket_for(value))] += 1
        p95_bucket = None
        if latencies:
            ordered = sorted(latencies)
            idx = max(0, min(len(ordered) - 1, math.ceil(len(ordered) * 0.95) - 1))
            p95_bucket = bucket_for(ordered[idx])
        return {
            "pid": os.getpid(),
            "socket": str(self.socket_path),
            "socket_type": "SOCK_DGRAM",
            "started_at": self.started_at,
            "generation": self.flush_count,
            "flush_count": self.flush_count,
            "total_packets": self.total_packets,
            "rejected_packets": self.rejected_packets,
            "metric_names": sorted(self.metric_names),
            "counters": {key: int(value) if value.is_integer() else value for key, value in self.counters.items()},
            "gauges": self.gauges,
            "latency_bucket_counts": buckets,
            "p95_latency_bucket_ms": p95_bucket,
            "last_packet_at": self.last_packet_at,
            "last_error": self.last_error,
        }

    def flush(self):
        self.flush_count += 1
        summary = self.current_summary()
        summary["generation"] = self.flush_count
        summary["flush_count"] = self.flush_count
        append_jsonl(self.rollup_path, summary)
        write_json_atomic(self.state_path, summary)

    def serve(self):
        signal.signal(signal.SIGTERM, self.handle_signal)
        signal.signal(signal.SIGINT, self.handle_signal)
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.bind_socket()
        self.write_pid()
        producer = threading.Thread(target=self.producer_loop, name="fixture-metric-producer", daemon=True)
        producer.start()
        last_flush = 0.0
        self.flush()
        while not self.stop_event.is_set():
            try:
                payload = self.sock.recv(8192).decode("utf-8", errors="replace")
            except socket.timeout:
                payload = ""
            except OSError as exc:
                self.last_error = str(exc)
                break
            if payload:
                for line in payload.splitlines():
                    try:
                        parsed = parse_statsd(line)
                    except ValueError as exc:
                        self.rejected_packets += 1
                        self.last_error = str(exc)
                        continue
                    if parsed is None:
                        continue
                    name, value, kind, _raw = parsed
                    self.update_metric(name, value, kind)
                    self.total_packets += 1
                    self.last_packet_at = time.time()
            now = time.monotonic()
            if now - last_flush >= self.flush_interval:
                self.flush()
                last_flush = now
        self.flush()
        self.cleanup()

    def cleanup(self):
        if self.sock is not None:
            self.sock.close()
        try:
            if self.socket_path.exists() and stat.S_ISSOCK(self.socket_path.stat().st_mode):
                st = self.socket_path.stat()
                if self.socket_node and st.st_dev == self.socket_node["dev"] and st.st_ino == self.socket_node["inode"]:
                    self.socket_path.unlink()
        except OSError:
            pass
        try:
            self.pid_file.unlink()
        except OSError:
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("--flush-interval", type=float, default=0.25)
    args = parser.parse_args()
    relay = StatsDRelay(args.socket, args.state_dir, args.pid_file, args.flush_interval)
    relay.serve()


if __name__ == "__main__":
    main()
