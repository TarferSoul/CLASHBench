#!/usr/bin/env python3
"""Receive, validate, and commit storage-replication generations."""
import argparse, collections, hashlib, json, os, pathlib, signal, socket, struct, time, zlib
running = True
def stop(*_):
    global running; running = False
def atomic(path, value):
    path = pathlib.Path(path); tmp = pathlib.Path(f"{path}.tmp.{os.getpid()}")
    tmp.write_text(json.dumps(value, sort_keys=True) + "\n"); os.chmod(tmp, 0o600); tmp.replace(path)
def main():
    p = argparse.ArgumentParser(); p.add_argument("--host", required=True); p.add_argument("--port", type=int, required=True); p.add_argument("--state", required=True); p.add_argument("--manifest", required=True); p.add_argument("--packet-bytes", type=int, required=True); p.add_argument("--segment-packets", type=int, required=True); a = p.parse_args()
    state, manifest = pathlib.Path(a.state), pathlib.Path(a.manifest); state.parent.mkdir(parents=True, exist_ok=True); manifest.parent.mkdir(parents=True, exist_ok=True); manifest.touch(mode=0o600, exist_ok=True)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20); sock.bind((a.host, a.port)); sock.settimeout(0.2)
    started = time.time(); first = last = None; received = valid = invalid = missing = committed = committed_bytes = segment_count = 0; segment_first = None; segment_digest = hashlib.sha256(); window = collections.deque(); values = {}
    def publish():
        now = time.monotonic()
        while window and now - window[0][0] > 2.0: window.popleft()
        span = 0 if first is None else last - first + 1; window_bytes = sum(x[1] for x in window); duration = max(now - window[0][0], 0.001) if window else 0.001
        values.update(healthy=running, pid=os.getpid(), started_at=started, received_packets=received, valid_packets=valid, invalid_packets=invalid, missing_packets=missing, first_sequence=first, last_sequence=last, sequence_span=span, sequence_continuity=valid / max(span, 1), loss_ratio=missing / max(valid + missing, 1), window_bitrate_bps=window_bytes * 8.0 / duration, committed_segments=committed, committed_bytes=committed_bytes, updated_at=time.time())
        atomic(state, values)
    publish()
    while running:
        try: packet, _ = sock.recvfrom(65535)
        except socket.timeout: publish(); continue
        except OSError: break
        received += 1
        if len(packet) != a.packet_bytes or len(packet) < 24: invalid += 1; continue
        magic, sequence, timestamp_ns = struct.unpack("!4sQQ", packet[:20]); stored = struct.unpack("!I", packet[20:24])[0]; body = packet[24:]
        if magic != b"RPL1" or zlib.crc32(packet[:20] + body) & 0xffffffff != stored: invalid += 1; continue
        if last is not None:
            if sequence <= last: invalid += 1; continue
            missing += max(0, sequence - last - 1)
        if first is None: first = sequence
        last = sequence; valid += 1; window.append((time.monotonic(), len(packet)))
        if segment_first is None: segment_first = sequence
        segment_count += 1; segment_digest.update(packet)
        if segment_count >= a.segment_packets:
            rec = {"generation": committed, "first_sequence": segment_first, "last_sequence": sequence, "packets": segment_count, "bytes": segment_count * a.packet_bytes, "sha256": segment_digest.hexdigest(), "committed_at": time.time(), "last_sender_timestamp_ns": timestamp_ns}
            with manifest.open("a") as stream: stream.write(json.dumps(rec, sort_keys=True) + "\n"); stream.flush(); os.fsync(stream.fileno())
            committed += 1; committed_bytes += rec["bytes"]; segment_first = None; segment_count = 0; segment_digest = hashlib.sha256()
        if valid % 128 == 0: publish()
    publish(); values.update(healthy=False, stopped_at=time.time()); atomic(state, values); sock.close()
if __name__ == "__main__":
    signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop); main()
