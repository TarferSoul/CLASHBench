#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import signal
import socket
import struct
import threading
import time


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


class Collector:
    def __init__(self, socket_path, state_path, auth_token, log_fd):
        self.socket_path = socket_path
        self.state_path = state_path
        self.auth_token = auth_token
        self.log_fd = log_fd
        self.listener = None
        self.stop_event = threading.Event()
        self.lock = threading.RLock()
        self.log_lock = threading.Lock()
        self.active = None
        self.total_durable = 0
        self.total_committed = 0
        self.session_history = []

    def write_state(self):
        with self.lock:
            active = dict(self.active) if self.active else None
            value = {
                "collector_pid": os.getpid(),
                "socket_path": self.socket_path,
                "active_session": active,
                "total_durable": self.total_durable,
                "total_committed": self.total_committed,
                "session_history": self.session_history[-32:],
                "updated_ns": time.time_ns(),
            }
        temp = self.state_path + ".tmp"
        with open(temp, "w") as handle:
            json.dump(value, handle, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, self.state_path)

    def append_frame(self, frame):
        with self.log_lock:
            offset = os.lseek(self.log_fd, 0, os.SEEK_END)
            stored = dict(frame)
            stored["offset"] = offset
            raw = (canonical(stored) + "\n").encode()
            os.write(self.log_fd, raw)
            os.fsync(self.log_fd)
            return offset

    @staticmethod
    def send(handle, value):
        handle.write((canonical(value) + "\n").encode())
        handle.flush()

    def handle(self, connection):
        peer_pid = peer_uid = -1
        session_id = "unknown"
        accepted = False
        try:
            peer_pid, peer_uid, _ = struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
            connection.settimeout(45)
            handle = connection.makefile("rwb", buffering=0)
            line = handle.readline()
            hello = json.loads(line) if line else {}
            session_id = str(hello.get("session_id", ""))
            expected = int(hello.get("expected_records", -1))
            context = str(hello.get("context", ""))
            if hello.get("type") != "HELLO" or hello.get("token") != self.auth_token or not session_id or expected < 1:
                self.send(handle, {"status": "UNAUTHORIZED"})
                return
            with self.lock:
                if self.active is not None:
                    self.send(handle, {
                        "status": "BUSY",
                        "active_session": self.active["session_id"],
                        "active_client_pid": self.active["client_pid"],
                        "active_durable": self.active["durable_records"],
                    })
                    return
                self.active = {
                    "session_id": session_id,
                    "client_pid": peer_pid,
                    "client_uid": peer_uid,
                    "context": context,
                    "expected_records": expected,
                    "durable_records": 0,
                    "accepted_ns": time.time_ns(),
                }
                accepted = True
                self.session_history.append({"event": "ACCEPT", "session_id": session_id, "client_pid": peer_pid, "at_ns": time.time_ns()})
                self.write_state()
            begin_offset = self.append_frame({
                "frame": "BEGIN", "session_id": session_id, "client_pid": peer_pid,
                "client_uid": peer_uid, "context": context, "expected_records": expected,
                "written_ns": time.time_ns(),
            })
            self.send(handle, {"status": "ACCEPTED", "session_id": session_id, "begin_offset": begin_offset})
            offsets = []
            digests = []
            for index in range(expected):
                line = handle.readline()
                message = json.loads(line) if line else {}
                if message.get("type") != "RECORD" or int(message.get("index", -1)) != index or not isinstance(message.get("payload"), dict):
                    raise ValueError(f"invalid record index {index}")
                payload = message["payload"]
                digest = hashlib.sha256(canonical(payload).encode()).hexdigest()
                offset = self.append_frame({
                    "frame": "DATA", "session_id": session_id, "index": index,
                    "payload_sha256": digest, "payload": payload, "written_ns": time.time_ns(),
                })
                offsets.append(offset)
                digests.append(digest)
                with self.lock:
                    self.total_durable += 1
                    self.active["durable_records"] = index + 1
                    self.active["last_offset"] = offset
                    self.write_state()
                self.send(handle, {"status": "DURABLE", "index": index, "offset": offset, "payload_sha256": digest})
            line = handle.readline()
            ending = json.loads(line) if line else {}
            if ending.get("type") != "COMMIT":
                raise ValueError("missing commit")
            transaction_digest = hashlib.sha256("".join(digests).encode()).hexdigest()
            commit_offset = self.append_frame({
                "frame": "COMMIT", "session_id": session_id, "record_count": expected,
                "transaction_sha256": transaction_digest, "written_ns": time.time_ns(),
            })
            with self.lock:
                self.total_committed += 1
                self.session_history.append({"event": "COMMIT", "session_id": session_id, "record_count": expected, "at_ns": time.time_ns()})
            self.send(handle, {
                "status": "COMMITTED", "session_id": session_id, "record_count": expected,
                "durable_offsets": offsets, "commit_offset": commit_offset,
                "transaction_sha256": transaction_digest,
            })
        except (BrokenPipeError, ConnectionResetError, TimeoutError, socket.timeout, ValueError, json.JSONDecodeError) as error:
            if accepted:
                try:
                    self.append_frame({"frame": "ABORT", "session_id": session_id, "reason": type(error).__name__, "written_ns": time.time_ns()})
                except OSError:
                    pass
                with self.lock:
                    self.session_history.append({"event": "ABORT", "session_id": session_id, "reason": type(error).__name__, "at_ns": time.time_ns()})
        finally:
            if accepted:
                with self.lock:
                    if self.active and self.active.get("session_id") == session_id and self.active.get("client_pid") == peer_pid:
                        self.active = None
                    self.write_state()
            connection.close()

    def shutdown(self, *_):
        self.stop_event.set()
        if self.listener:
            self.listener.close()

    def run(self):
        try:
            os.unlink(self.socket_path)
        except FileNotFoundError:
            pass
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(self.socket_path)
        os.chmod(self.socket_path, 0o660)
        self.listener.listen(32)
        self.listener.settimeout(0.5)
        self.write_state()
        while not self.stop_event.is_set():
            try:
                connection, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            threading.Thread(target=self.handle, args=(connection,), daemon=True).start()
        try:
            os.unlink(self.socket_path)
        except FileNotFoundError:
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--log-fd", required=True, type=int)
    args = parser.parse_args()
    collector = Collector(args.socket, args.state, args.token, args.log_fd)
    signal.signal(signal.SIGTERM, collector.shutdown)
    signal.signal(signal.SIGINT, collector.shutdown)
    collector.run()


if __name__ == "__main__":
    main()
