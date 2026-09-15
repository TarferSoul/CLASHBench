#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import signal
import socketserver
import threading
import time


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def utc_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


class State:
    def __init__(self, args):
        self.args = args
        self.secret = pathlib.Path(args.token_file).read_text().strip()
        self.log_path = pathlib.Path(args.append_log)
        self.state_path = pathlib.Path(args.state)
        self.socket_path = pathlib.Path(args.socket)
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        self.log_path.touch(exist_ok=True)
        self.handle = self.log_path.open("ab", buffering=0)
        self.sequence = self._next_sequence()
        self.lock = threading.RLock()
        self.started_at = utc_now()
        self.started_monotonic = time.monotonic()
        self.tokens = float(args.burst_tokens)
        self.last_refill = time.monotonic()
        self.admitted = {}
        self.throttled = {}
        self.dropped = {}
        self.protocol_errors = 0
        self.connections = 0
        self.fsync_count = 0
        self.fsync_ms_max = 0.0
        self.fsync_samples = []
        self._persist_locked()

    def _next_sequence(self):
        high = -1
        for line in self.log_path.read_text(errors="replace").splitlines():
            try: high = max(high, int(json.loads(line).get("sequence", -1)))
            except Exception: continue
        return high + 1

    def _refill_locked(self):
        now = time.monotonic()
        self.tokens = min(float(self.args.burst_tokens), self.tokens + max(0, now-self.last_refill)*float(self.args.refill_per_second))
        self.last_refill = now

    def _persist_locked(self):
        self._refill_locked()
        log_stat = self.log_path.stat()
        socket_stat = self.socket_path.stat()
        payload = {
            "status": "OK",
            "protocol": "unix-stream-jsonl-append",
            "pid": os.getpid(),
            "started_at": self.started_at,
            "uptime_seconds": round(time.monotonic()-self.started_monotonic,3),
            "socket": str(self.socket_path),
            "socket_device": socket_stat.st_dev,
            "socket_inode": socket_stat.st_ino,
            "append_log_device": log_stat.st_dev,
            "append_log_inode": log_stat.st_ino,
            "append_log_size": log_stat.st_size,
            "token_bucket": {"refill_events_per_second": self.args.refill_per_second, "burst_tokens": self.args.burst_tokens, "available_tokens": round(self.tokens,3)},
            "admitted_by_owner": dict(sorted(self.admitted.items())),
            "throttled_by_owner": dict(sorted(self.throttled.items())),
            "dropped_by_owner": dict(sorted(self.dropped.items())),
            "total_admitted": sum(self.admitted.values()),
            "total_throttled": sum(self.throttled.values()),
            "total_dropped": sum(self.dropped.values()),
            "protocol_errors": self.protocol_errors,
            "connections": self.connections,
            "next_sequence": self.sequence,
            "fsync_count": self.fsync_count,
            "fsync_ms_max": round(self.fsync_ms_max,3),
            "fsync_ms_mean": round(sum(self.fsync_samples)/len(self.fsync_samples),3) if self.fsync_samples else 0.0,
            "fsync_ms_p95": round(sorted(self.fsync_samples)[max(0,int(len(self.fsync_samples)*.95)-1)],3) if self.fsync_samples else 0.0,
            "updated_at": utc_now(),
        }
        tmp = self.state_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload,sort_keys=True,indent=2)+"\n")
        os.chmod(tmp,0o600); tmp.replace(self.state_path)
        return payload

    def snapshot(self):
        with self.lock: return self._persist_locked()

    def connect(self):
        with self.lock:
            self.connections += 1
            self._persist_locked()

    def error(self):
        with self.lock:
            self.protocol_errors += 1
            self._persist_locked()

    def append(self, request):
        owner=str(request.get("owner") or "unknown"); event_id=str(request.get("event_id") or "")
        with self.lock:
            self._refill_locked()
            if self.tokens < 1:
                self.throttled[owner]=self.throttled.get(owner,0)+1
                self.dropped[owner]=self.dropped.get(owner,0)+1
                self._persist_locked()
                return {"status":"THROTTLED","event_id":event_id,"retry_after_ms":14,"available_tokens":round(self.tokens,3)}
            self.tokens -= 1
            frame={
                "record_type":"PROVENANCE_LEDGER_EVENT","sequence":self.sequence,"owner":owner,
                "client_id":str(request.get("client_id") or ""),"transaction":str(request.get("transaction") or ""),
                "stream":str(request.get("stream") or ""),"event_id":event_id,"event_type":str(request.get("event_type") or ""),
                "payload":request.get("payload") or {},"received_at":utc_now(),
            }
            frame["payload_sha256"]=hashlib.sha256(canonical(frame["payload"]).encode()).hexdigest()
            raw=(canonical(frame)+"\n").encode(); offset=self.handle.tell(); self.handle.write(raw)
            started=time.perf_counter(); os.fsync(self.handle.fileno()); fsync_ms=(time.perf_counter()-started)*1000
            durable_offset=offset+len(raw); log_stat=self.log_path.stat()
            self.sequence += 1; self.fsync_count += 1; self.fsync_ms_max=max(self.fsync_ms_max,fsync_ms); self.fsync_samples.append(fsync_ms); self.fsync_samples=self.fsync_samples[-512:]
            self.admitted[owner]=self.admitted.get(owner,0)+1; self._persist_locked()
            receipt={"status":"ADMITTED","event_id":event_id,"sequence":frame["sequence"],"durable_offset":durable_offset,"append_log_inode":log_stat.st_ino,"payload_sha256":frame["payload_sha256"],"fsync_ms":round(fsync_ms,3)}
            receipt["receipt_sha256"]=hashlib.sha256(canonical(receipt).encode()).hexdigest()
            return receipt


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        self.server.state.connect()
        while True:
            raw=self.rfile.readline(1024*1024)
            if not raw: return
            try: request=json.loads(raw.decode())
            except Exception:
                self.server.state.error(); self.send({"status":"BAD_REQUEST"}); continue
            if request.get("action")=="stats": self.send(self.server.state.snapshot()); continue
            if request.get("action")!="append": self.server.state.error(); self.send({"status":"BAD_REQUEST"}); continue
            if request.get("token")!=self.server.state.secret: self.server.state.error(); self.send({"status":"AUTH_FAILED"}); continue
            if not request.get("owner") or not request.get("event_id"): self.server.state.error(); self.send({"status":"BAD_REQUEST"}); continue
            self.send(self.server.state.append(request))

    def send(self, payload):
        self.wfile.write((json.dumps(payload,sort_keys=True)+"\n").encode()); self.wfile.flush()


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads=True


def main():
    parser=argparse.ArgumentParser(); parser.add_argument("--socket",required=True); parser.add_argument("--append-log",required=True); parser.add_argument("--state",required=True); parser.add_argument("--token-file",required=True); parser.add_argument("--refill-per-second",required=True,type=float); parser.add_argument("--burst-tokens",required=True,type=float); args=parser.parse_args()
    socket_path=pathlib.Path(args.socket); socket_path.parent.mkdir(parents=True,exist_ok=True); socket_path.unlink(missing_ok=True)
    server=Server(str(socket_path),Handler); os.chmod(socket_path,0o666); server.state=State(args)
    def stop(*_): threading.Thread(target=server.shutdown,daemon=True).start()
    signal.signal(signal.SIGTERM,stop); signal.signal(signal.SIGINT,stop)
    print(f"COLLECTOR_READY pid={os.getpid()} socket={socket_path} refill_eps={args.refill_per_second} burst={args.burst_tokens}",flush=True)
    server.serve_forever(poll_interval=.1); server.state.handle.close(); server.server_close(); socket_path.unlink(missing_ok=True)


if __name__=="__main__": main()
