#!/usr/bin/env python3
"""Pace sequence-numbered storage-replication blocks at a fixed bitrate."""
import argparse, hashlib, json, os, pathlib, signal, socket, struct, time, zlib
from link_budget import SharedTokenBucket
running = True
def stop(*_):
    global running; running = False
def atomic(path, value):
    path = pathlib.Path(path); tmp = pathlib.Path(f"{path}.tmp.{os.getpid()}"); tmp.write_text(json.dumps(value, sort_keys=True) + "\n"); os.chmod(tmp, 0o600); tmp.replace(path)
def make_frame(seq, size):
    stamp = time.time_ns(); prefix = struct.pack("!4sQQ", b"RPL1", seq, stamp); body_size = size - 24; block = struct.pack("!QQ", seq // 64, seq % 64); seed = hashlib.sha256(b"replication-block" + seq.to_bytes(8, "big")).digest(); body = (block + seed * ((body_size // len(seed)) + 1))[:body_size]; return prefix + struct.pack("!I", zlib.crc32(prefix + body) & 0xffffffff) + body
def main():
    p = argparse.ArgumentParser(); p.add_argument("--host", required=True); p.add_argument("--port", type=int, required=True); p.add_argument("--state", required=True); p.add_argument("--rate-bps", type=int, required=True); p.add_argument("--packet-bytes", type=int, required=True); p.add_argument("--budget", required=True); a = p.parse_args()
    state = pathlib.Path(a.state); state.parent.mkdir(parents=True, exist_ok=True); bucket = SharedTokenBucket(a.budget); sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); sock.settimeout(1.0); started = time.time(); mono = time.monotonic(); seq = sent_bytes = errors = 0; last = 0.0; atomic(state, {"healthy": True, "pid": os.getpid(), "started_at": started, "target_bps": a.rate_bps, "packet_bytes": a.packet_bytes, "sent_packets": 0, "sent_bytes": 0, "errors": 0})
    while running:
        packet = make_frame(seq, a.packet_bytes)
        try:
            bucket.consume(len(packet))
            sent = sock.sendto(packet, (a.host, a.port)); seq += 1; sent_bytes += sent
        except socket.timeout: errors += 1
        except OSError: errors += 1
        delay = mono + sent_bytes * 8.0 / a.rate_bps - time.monotonic()
        if delay > 0: time.sleep(min(delay, 0.02))
        now = time.monotonic()
        if now - last >= 0.2:
            elapsed = max(now - mono, 0.001); atomic(state, {"healthy": True, "pid": os.getpid(), "started_at": started, "target_bps": a.rate_bps, "packet_bytes": a.packet_bytes, "sent_packets": seq, "sent_bytes": sent_bytes, "mean_pacing_bps": sent_bytes * 8.0 / elapsed, "errors": errors, "last_sequence": seq - 1, "updated_at": time.time()}); last = now
    atomic(state, {"healthy": False, "pid": os.getpid(), "started_at": started, "target_bps": a.rate_bps, "packet_bytes": a.packet_bytes, "sent_packets": seq, "sent_bytes": sent_bytes, "errors": errors, "stopped_at": time.time()}); sock.close()
if __name__ == "__main__":
    signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop); main()
