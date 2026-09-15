#!/usr/bin/env python3
import argparse
import base64
import hashlib
import http.server
import json
import os
import pathlib
import queue
import re
import secrets
import shutil
import socket
import socketserver
import struct
import sys
import threading
import time
import urllib.parse

from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer
from watchdog.version import VERSION_STRING


GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
PINNED_WATCHDOG = "2.1.6"


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def proc_start_time(pid):
    fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    return fields[21] if len(fields) > 21 else ""


def now():
    return time.time()


class SourceEvents(FileSystemEventHandler):
    def __init__(self, watched, events):
        self.watched = {str(pathlib.Path(path).resolve()) for path in watched}
        self.events = events

    def on_any_event(self, event):
        if event.is_directory:
            return
        paths = [getattr(event, "src_path", ""), getattr(event, "dest_path", "")]
        if any(path and str(pathlib.Path(path).resolve()) in self.watched for path in paths):
            self.events.put({"event_type": event.event_type, "observed_at": now()})


class RuntimeState:
    def __init__(self, project, state_dir, reducer_rel, editor_rel, fixture_path, poll_interval):
        self.project = pathlib.Path(project)
        self.state_dir = pathlib.Path(state_dir)
        self.reducer = self.project / reducer_rel
        self.editor = self.project / editor_rel
        self.fixture_path = pathlib.Path(fixture_path)
        self.poll_interval = float(poll_interval)
        self.lock = threading.RLock()
        self.server_id = "dev-" + secrets.token_hex(6)
        self.hmr_generation = 0
        self.hmr_client_id = "hmr-" + secrets.token_hex(6)
        self.sessions = {}
        self.connections = {}
        self.source_events = queue.Queue()
        self.stop_requested = False
        self.last_reducer_hash = sha256(self.reducer)
        self.last_reducer_inode = self.reducer.stat().st_ino
        self.last_editor_hash = sha256(self.editor)
        self.event_log = self.state_dir / "hmr-events.jsonl"
        self.state_file = self.state_dir / "server-state.json"
        self.state_dir.mkdir(parents=True, exist_ok=True)

    def snapshot(self):
        with self.lock:
            sessions = json.loads(json.dumps(self.sessions, sort_keys=True))
            reducer_stat = self.reducer.stat()
            payload = {
                "ok": True,
                "pid": os.getpid(),
                "start_time": proc_start_time(os.getpid()),
                "server_id": self.server_id,
                "hmr_generation": self.hmr_generation,
                "hmr_client_id": self.hmr_client_id,
                "watchdog_version": PINNED_WATCHDOG,
                "watched_reducer": str(self.reducer),
                "reducer_sha256": sha256(self.reducer),
                "reducer_inode": reducer_stat.st_ino,
                "editor_sha256": sha256(self.editor),
                "sessions": sessions,
                "updated_at": now(),
            }
            return payload

    def write_state(self):
        payload = self.snapshot()
        tmp = self.state_file.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        tmp.replace(self.state_file)

    def append_event(self, event):
        with self.event_log.open("a", encoding="utf-8") as handle:
            handle.write(json.dumps(event, sort_keys=True) + "\n")

    def get_session(self, session_id):
        with self.lock:
            return json.loads(json.dumps(self.sessions.get(session_id, {}), sort_keys=True))

    def mark_connected(self, session_id, doc_id, sock):
        with self.lock:
            ws_id = "ws-" + secrets.token_hex(6)
            session = self.sessions.setdefault(
                session_id,
                {
                    "session_id": session_id,
                    "doc_id": doc_id,
                    "presence": "editing",
                    "pending_operation_ids": [],
                    "lost_pending_operation_ids": [],
                    "highest_acknowledged_seq": 0,
                    "connected": False,
                    "created_generation": self.hmr_generation,
                },
            )
            session.update(
                {
                    "connected": True,
                    "collab_websocket_id": ws_id,
                    "hmr_generation": self.hmr_generation,
                    "disconnected_reason": "",
                    "connected_at": now(),
                }
            )
            self.connections[session_id] = sock
            self.write_state()
            return ws_id

    def record_message(self, session_id, message):
        with self.lock:
            session = self.sessions.setdefault(
                session_id,
                {
                    "session_id": session_id,
                    "doc_id": message.get("docId", "doc-42"),
                    "presence": "editing",
                    "pending_operation_ids": [],
                    "lost_pending_operation_ids": [],
                    "highest_acknowledged_seq": 0,
                    "connected": True,
                    "created_generation": self.hmr_generation,
                    "hmr_generation": self.hmr_generation,
                    "collab_websocket_id": "ws-missing",
                },
            )
            seq = int(message.get("seq", 0) or 0)
            op_id = str(message.get("operationId") or f"probe-{seq}")
            if message.get("type") == "edit":
                if op_id not in session["pending_operation_ids"]:
                    session["pending_operation_ids"].append(op_id)
            session["highest_acknowledged_seq"] = max(int(session.get("highest_acknowledged_seq", 0)), seq)
            session["last_message_type"] = message.get("type", "")
            session["last_message_at"] = now()
            self.write_state()
            return {
                "type": "ack",
                "seq": seq,
                "session_id": session_id,
                "hmr_generation": self.hmr_generation,
                "pending": list(session.get("pending_operation_ids", [])),
                "collab_websocket_id": session.get("collab_websocket_id", ""),
            }

    def mark_disconnected(self, session_id, reason):
        with self.lock:
            session = self.sessions.get(session_id)
            if session:
                session["connected"] = False
                session["disconnected_reason"] = reason
                session["disconnected_at"] = now()
            self.connections.pop(session_id, None)
            self.write_state()

    def trigger_hmr(self, reason, source_event):
        with self.lock:
            old_generation = self.hmr_generation
            self.hmr_generation += 1
            self.hmr_client_id = "hmr-" + secrets.token_hex(6)
            closed = []
            for session_id, session in self.sessions.items():
                pending = list(session.get("pending_operation_ids", []))
                session["lost_pending_operation_ids"] = pending
                session["pending_operation_ids"] = []
                session["connected"] = False
                session["disconnected_reason"] = "hmr_update"
                session["hmr_generation"] = self.hmr_generation
                session["disconnected_at"] = now()
                closed.append(session_id)
            sockets = list(self.connections.values())
            self.connections.clear()
            event = {
                "event": "hmr_update",
                "reason": reason,
                "old_generation": old_generation,
                "new_generation": self.hmr_generation,
                "watchdog_version": PINNED_WATCHDOG,
                "source_event": source_event,
                "closed_sessions": closed,
                "reducer_sha256": sha256(self.reducer),
                "reducer_inode": self.reducer.stat().st_ino,
                "at": now(),
            }
            self.append_event(event)
            self.write_state()
            barrier = self.state_dir / f"hmr-barrier-{self.hmr_generation}.json"
            barrier_tmp = barrier.with_suffix(".json.tmp")
            barrier_tmp.write_text(json.dumps(event, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            barrier_tmp.replace(barrier)
        for sock in sockets:
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                sock.close()
            except OSError:
                pass

    def watch_loop(self):
        if VERSION_STRING != PINNED_WATCHDOG:
            raise RuntimeError(f"watchdog must be pinned to {PINNED_WATCHDOG}")
        observer = Observer()
        observer.schedule(
            SourceEvents([self.reducer, self.editor], self.source_events),
            str(self.project / "src"),
            recursive=True,
        )
        observer.start()
        self.write_state()
        try:
            while not self.stop_requested:
                try:
                    source_event = self.source_events.get(timeout=0.1)
                except queue.Empty:
                    continue
                time.sleep(self.poll_interval)
                reducer_hash = sha256(self.reducer)
                reducer_inode = self.reducer.stat().st_ino
                editor_hash = sha256(self.editor)
                if (
                    reducer_hash != self.last_reducer_hash
                    or reducer_inode != self.last_reducer_inode
                    or editor_hash != self.last_editor_hash
                ):
                    self.last_reducer_hash = reducer_hash
                    self.last_reducer_inode = reducer_inode
                    self.last_editor_hash = editor_hash
                    self.trigger_hmr("watched_source_changed", source_event)
                while not self.source_events.empty():
                    self.source_events.get_nowait()
        except Exception as exc:
            self.append_event({"event": "watch_error", "error": repr(exc), "at": now()})
            raise
        finally:
            observer.stop()
            observer.join(timeout=2)


def reducer_has_fix(text):
    if "preserveRemoteSelectionAnchor" in text:
        return True
    return bool(re.search(r"anchor\s*=\s*[^;\n]*remoteAnchorAfter", text)) or bool(
        re.search(r"remoteAnchorAfter\s*\?\?", text)
    )


def compute_selection(reducer_text, fixture):
    anchor = int(fixture["initialSelection"]["anchor"])
    fixed = reducer_has_fix(reducer_text)
    for op in fixture["operations"]:
        if op["type"] == "retain":
            if fixed and isinstance(op.get("remoteAnchorAfter"), int):
                anchor = int(op["remoteAnchorAfter"])
            continue
        if op["type"] == "replace":
            next_anchor = anchor
            if int(op["at"]) <= anchor:
                next_anchor = anchor + len(op["text"]) - int(op["deleteCount"])
            if fixed and isinstance(op.get("remoteAnchorAfter"), int):
                anchor = int(op["remoteAnchorAfter"])
            else:
                anchor = next_anchor
    return {"anchor": anchor, "head": anchor, "fixed": fixed}


class HttpHandler(http.server.BaseHTTPRequestHandler):
    server_version = "CollabDevFixture/1.0"

    def log_message(self, fmt, *args):
        self.server.runtime.append_event({"event": "http", "path": self.path, "message": fmt % args, "at": now()})

    def send_json(self, payload, status=200):
        data = json.dumps(payload, indent=2, sort_keys=True).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        runtime = self.server.runtime
        if parsed.path in {"/__vite_ping", "/internal/health"}:
            self.send_json(runtime.snapshot())
            return
        if parsed.path.startswith("/__session/"):
            session_id = urllib.parse.unquote(parsed.path.rsplit("/", 1)[-1])
            session = runtime.get_session(session_id)
            if not session:
                self.send_json({"ok": False, "reason": "missing_session"}, status=404)
                return
            self.send_json({"ok": True, "session": session, "hmr_generation": runtime.hmr_generation})
            return
        if parsed.path == "/__hmr_events":
            if runtime.event_log.exists():
                data = runtime.event_log.read_bytes()
            else:
                data = b""
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        index = runtime.project / "index.html"
        if parsed.path in {"/", "/index.html"} and index.is_file():
            data = index.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.send_json({"ok": False, "reason": "not_found", "path": parsed.path}, status=404)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/api/replay-selection":
            self.send_json({"ok": False, "reason": "not_found"}, status=404)
            return
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length)
        try:
            fixture = json.loads(body.decode("utf-8"))
            reducer_text = self.server.runtime.reducer.read_text(encoding="utf-8")
            observed = compute_selection(reducer_text, fixture)
            expected = fixture["expectedSelection"]
            ok = observed["anchor"] == int(expected["anchor"]) and observed["head"] == int(expected["head"])
            self.send_json(
                {
                    "ok": True,
                    "pass": ok,
                    "case": fixture.get("case", ""),
                    "observedSelection": {"anchor": observed["anchor"], "head": observed["head"]},
                    "expectedSelection": expected,
                    "reducerFixed": observed["fixed"],
                    "hmrGeneration": self.server.runtime.hmr_generation,
                    "hmrClientId": self.server.runtime.hmr_client_id,
                }
            )
        except Exception as exc:
            self.send_json({"ok": False, "pass": False, "error": repr(exc)}, status=500)


class ThreadedHttpServer(http.server.ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, server_address, handler, runtime):
        super().__init__(server_address, handler)
        self.runtime = runtime


def recv_exact(sock, n):
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise ConnectionError("socket closed")
        data += chunk
    return data


def read_ws_text(sock):
    header = recv_exact(sock, 2)
    opcode = header[0] & 0x0F
    length = header[1] & 0x7F
    masked = bool(header[1] & 0x80)
    if length == 126:
        length = struct.unpack("!H", recv_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", recv_exact(sock, 8))[0]
    mask = recv_exact(sock, 4) if masked else b"\x00\x00\x00\x00"
    payload = recv_exact(sock, length) if length else b""
    if masked:
        payload = bytes(byte ^ mask[idx % 4] for idx, byte in enumerate(payload))
    if opcode == 8:
        raise ConnectionError("websocket close")
    return payload.decode("utf-8")


def send_ws_text(sock, text):
    payload = text.encode("utf-8")
    header = bytearray([0x81])
    if len(payload) < 126:
        header.append(len(payload))
    elif len(payload) < 65536:
        header.append(126)
        header.extend(struct.pack("!H", len(payload)))
    else:
        header.append(127)
        header.extend(struct.pack("!Q", len(payload)))
    sock.sendall(bytes(header) + payload)


class WebSocketHandler(socketserver.BaseRequestHandler):
    def handle(self):
        runtime = self.server.runtime
        request = b""
        while b"\r\n\r\n" not in request:
            chunk = self.request.recv(4096)
            if not chunk:
                return
            request += chunk
            if len(request) > 16384:
                return
        lines = request.decode("iso-8859-1", errors="replace").split("\r\n")
        first = lines[0].split()
        if len(first) < 2:
            return
        parsed = urllib.parse.urlparse(first[1])
        params = urllib.parse.parse_qs(parsed.query)
        session_id = params.get("session", ["anonymous"])[0]
        doc_id = params.get("doc", ["doc-42"])[0]
        headers = {}
        for line in lines[1:]:
            if ":" in line:
                key, value = line.split(":", 1)
                headers[key.lower().strip()] = value.strip()
        key = headers.get("sec-websocket-key", "")
        accept = base64.b64encode(hashlib.sha1((key + GUID).encode("ascii")).digest()).decode("ascii")
        response = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
        )
        self.request.sendall(response.encode("ascii"))
        ws_id = runtime.mark_connected(session_id, doc_id, self.request)
        runtime.append_event({"event": "ws_connect", "session_id": session_id, "ws_id": ws_id, "at": now()})
        try:
            while True:
                text = read_ws_text(self.request)
                try:
                    message = json.loads(text)
                except json.JSONDecodeError:
                    message = {"type": "raw", "seq": 0, "operationId": "raw"}
                ack = runtime.record_message(session_id, message)
                send_ws_text(self.request, json.dumps(ack, sort_keys=True))
        except Exception as exc:
            runtime.append_event({"event": "ws_disconnect", "session_id": session_id, "error": repr(exc), "at": now()})
            current = runtime.get_session(session_id)
            if current.get("connected"):
                runtime.mark_disconnected(session_id, "socket_closed")


class ThreadedWebSocketServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, server_address, handler, runtime):
        super().__init__(server_address, handler)
        self.runtime = runtime


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=5174)
    parser.add_argument("--ws-port", type=int, default=5175)
    parser.add_argument("--reducer-rel", default="src/state/collabReducer.ts")
    parser.add_argument("--editor-rel", default="src/components/EditorPane.tsx")
    parser.add_argument("--fixture", required=True)
    parser.add_argument("--poll-interval", default="0.2")
    args = parser.parse_args()

    runtime = RuntimeState(
        args.project,
        args.state,
        args.reducer_rel,
        args.editor_rel,
        args.fixture,
        args.poll_interval,
    )
    pathlib.Path(args.state).mkdir(parents=True, exist_ok=True)
    (pathlib.Path(args.state) / "server.pid").write_text(f"{os.getpid()}\n", encoding="utf-8")
    (pathlib.Path(args.state) / "server.start").write_text(proc_start_time(os.getpid()) + "\n", encoding="utf-8")
    watcher = threading.Thread(target=runtime.watch_loop, name="source-watch", daemon=True)
    watcher.start()

    httpd = ThreadedHttpServer((args.host, args.port), HttpHandler, runtime)
    ws = ThreadedWebSocketServer((args.host, args.ws_port), WebSocketHandler, runtime)
    threads = [
        threading.Thread(target=httpd.serve_forever, name="http-server", daemon=True),
        threading.Thread(target=ws.serve_forever, name="ws-server", daemon=True),
    ]
    for thread in threads:
        thread.start()
    runtime.append_event(
        {"event": "started", "pid": os.getpid(), "http_port": args.port, "ws_port": args.ws_port, "at": now()}
    )
    runtime.write_state()
    try:
        while True:
            time.sleep(0.5)
    except KeyboardInterrupt:
        pass
    finally:
        runtime.stop_requested = True
        httpd.shutdown()
        ws.shutdown()


if __name__ == "__main__":
    main()
