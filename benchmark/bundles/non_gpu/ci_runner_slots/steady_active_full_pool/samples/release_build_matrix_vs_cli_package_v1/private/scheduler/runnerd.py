#!/usr/bin/env python3
"""ForgeCI Local Runner Service: a bounded FIFO executor scheduler."""

import argparse
import collections
import hashlib
import json
import os
import pathlib
import signal
import socketserver
import subprocess
import threading
import time

VERSION = "1.4.2"


def now():
    return time.time()


def digest_command(command):
    payload = json.dumps(command, separators=(",", ":"), ensure_ascii=True).encode()
    return hashlib.sha256(payload).hexdigest()


class Scheduler:
    def __init__(self, pool, capacity, state_dir):
        self.pool = pool
        self.capacity = capacity
        self.state_dir = pathlib.Path(state_dir)
        self.jobs_dir = self.state_dir / "jobs"
        self.jobs_dir.mkdir(parents=True, exist_ok=True)
        self.lock = threading.RLock()
        self.changed = threading.Condition(self.lock)
        self.jobs = {}
        self.waiting = collections.deque()
        self.slots = [None] * capacity
        self.stopping = False
        self.dispatcher = threading.Thread(target=self.dispatch_loop, daemon=True)

    def emit(self, event, **fields):
        record = {
            "event": event,
            "time": now(),
            "scheduler_pid": os.getpid(),
            "pool": self.pool,
            **fields,
        }
        print(json.dumps(record, sort_keys=True), flush=True)

    def start(self):
        self.emit("server_ready", version=VERSION, capacity=self.capacity)
        self.dispatcher.start()

    def submit(self, request):
        job_id = str(request.get("job_id", ""))
        workflow_id = str(request.get("workflow_id", ""))
        command = request.get("command")
        cwd = str(request.get("cwd", ""))
        if not job_id or not workflow_id:
            raise ValueError("job_id and workflow_id are required")
        if any(ch not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-" for ch in job_id):
            raise ValueError("invalid job_id")
        if not isinstance(command, list) or not command or not all(isinstance(x, str) and x for x in command):
            raise ValueError("command must be a nonempty string array")
        if not pathlib.Path(cwd).is_dir():
            raise ValueError("cwd does not exist")
        with self.changed:
            if job_id in self.jobs:
                raise ValueError("job_id already exists")
            submitted = now()
            job = {
                "job_id": job_id,
                "workflow_id": workflow_id,
                "command": command,
                "command_sha256": digest_command(command),
                "cwd": cwd,
                "state": "queued",
                "submitted_at": submitted,
                "dispatched_at": None,
                "completed_at": None,
                "slot": None,
                "lease_id": None,
                "pid": None,
                "rc": None,
            }
            self.jobs[job_id] = job
            self.waiting.append(job_id)
            self.emit(
                "job_submitted",
                job_id=job_id,
                workflow_id=workflow_id,
                command_sha256=job["command_sha256"],
                cwd=cwd,
                queued_jobs=len(self.waiting),
            )
            self.changed.notify_all()
            return self.public_job(job)

    def public_job(self, job):
        return {key: job[key] for key in (
            "job_id", "workflow_id", "state", "submitted_at", "dispatched_at",
            "completed_at", "slot", "lease_id", "pid", "rc", "command_sha256", "cwd"
        )}

    def snapshot(self, job_id=None):
        with self.lock:
            if job_id:
                if job_id not in self.jobs:
                    raise ValueError("unknown job_id")
                return {"pool": self.pool, "job": self.public_job(self.jobs[job_id])}
            active = [self.public_job(job) for job in self.jobs.values() if job["state"] == "running"]
            queued = [self.public_job(job) for job in self.jobs.values() if job["state"] == "queued"]
            return {
                "version": VERSION,
                "pool": self.pool,
                "capacity": self.capacity,
                "busy_slots": len(active),
                "free_slots": self.capacity - len(active),
                "queued_jobs": len(queued),
                "active": sorted(active, key=lambda item: item["slot"]),
                "queued": sorted(queued, key=lambda item: item["submitted_at"]),
            }

    def cancel(self, job_id):
        with self.changed:
            if job_id not in self.jobs:
                raise ValueError("unknown job_id")
            job = self.jobs[job_id]
            if job["state"] == "queued":
                self.waiting.remove(job_id)
                job.update(state="cancelled", completed_at=now(), rc=143)
                self.emit("job_cancelled", job_id=job_id, workflow_id=job["workflow_id"], phase="queued")
            elif job["state"] == "running":
                try:
                    os.killpg(job["pid"], signal.SIGTERM)
                except ProcessLookupError:
                    pass
                self.emit(
                    "job_cancel_requested",
                    job_id=job_id,
                    workflow_id=job["workflow_id"],
                    lease_id=job["lease_id"],
                    pid=job["pid"],
                )
            self.changed.notify_all()
            return self.public_job(job)

    def dispatch_loop(self):
        while True:
            with self.changed:
                self.changed.wait_for(
                    lambda: self.stopping or (self.waiting and any(value is None for value in self.slots)),
                    timeout=0.2,
                )
                if self.stopping:
                    return
                while self.waiting and any(value is None for value in self.slots):
                    job_id = self.waiting.popleft()
                    slot = self.slots.index(None)
                    self.launch(job_id, slot)

    def launch(self, job_id, slot):
        job = self.jobs[job_id]
        stdout_path = self.jobs_dir / f"{job_id}.stdout"
        stderr_path = self.jobs_dir / f"{job_id}.stderr"
        stdout_handle = stdout_path.open("ab", buffering=0)
        stderr_handle = stderr_path.open("ab", buffering=0)
        process = subprocess.Popen(
            job["command"],
            cwd=job["cwd"],
            stdin=subprocess.DEVNULL,
            stdout=stdout_handle,
            stderr=stderr_handle,
            start_new_session=True,
            env={**os.environ, "FORGECI_POOL": self.pool, "FORGECI_JOB_ID": job_id, "FORGECI_SLOT": str(slot)},
        )
        dispatched = now()
        lease_id = f"{self.pool}-slot{slot}-{int(dispatched * 1000000)}"
        job.update(
            state="running",
            dispatched_at=dispatched,
            slot=slot,
            lease_id=lease_id,
            pid=process.pid,
            process=process,
            stdout_handle=stdout_handle,
            stderr_handle=stderr_handle,
        )
        self.slots[slot] = job_id
        self.emit(
            "job_dispatched",
            job_id=job_id,
            workflow_id=job["workflow_id"],
            command_sha256=job["command_sha256"],
            cwd=job["cwd"],
            lease_id=lease_id,
            slot=slot,
            pid=process.pid,
            dispatch_latency_ms=round((dispatched - job["submitted_at"]) * 1000, 3),
            busy_slots=sum(item is not None for item in self.slots),
            capacity=self.capacity,
        )
        threading.Thread(target=self.monitor, args=(job_id,), daemon=True).start()

    def monitor(self, job_id):
        with self.lock:
            job = self.jobs[job_id]
            process = job["process"]
        rc = process.wait()
        completed = now()
        with self.changed:
            job = self.jobs[job_id]
            slot = job["slot"]
            job["stdout_handle"].close()
            job["stderr_handle"].close()
            job.update(state="succeeded" if rc == 0 else "failed", rc=rc, completed_at=completed)
            self.slots[slot] = None
            self.emit(
                "job_completed",
                job_id=job_id,
                workflow_id=job["workflow_id"],
                lease_id=job["lease_id"],
                slot=slot,
                pid=job["pid"],
                rc=rc,
                duration_ms=round((completed - job["dispatched_at"]) * 1000, 3),
            )
            self.changed.notify_all()

    def stop(self):
        with self.changed:
            self.stopping = True
            running = [job for job in self.jobs.values() if job["state"] == "running"]
            self.changed.notify_all()
        for job in running:
            try:
                os.killpg(job["pid"], signal.SIGTERM)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 2
        for job in running:
            process = job.get("process")
            if not process:
                continue
            try:
                process.wait(timeout=max(0.01, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(job["pid"], signal.SIGKILL)
                except ProcessLookupError:
                    pass
        self.emit("server_stopped")


class Handler(socketserver.StreamRequestHandler):
    def handle(self):
        try:
            raw = self.rfile.readline(1024 * 1024)
            request = json.loads(raw)
            action = request.get("action")
            if action == "status":
                result = self.server.scheduler.snapshot(request.get("job_id"))
            elif action == "submit":
                result = self.server.scheduler.submit(request)
            elif action == "cancel":
                result = self.server.scheduler.cancel(str(request.get("job_id", "")))
            else:
                raise ValueError("unknown action")
            response = {"ok": True, "result": result}
        except Exception as exc:
            response = {"ok": False, "error": f"{type(exc).__name__}: {exc}"}
        self.wfile.write((json.dumps(response, sort_keys=True) + "\n").encode())


class Server(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--pool", required=True)
    parser.add_argument("--capacity", required=True, type=int)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--pid-file", required=True)
    args = parser.parse_args()
    if args.capacity < 1:
        raise SystemExit("capacity must be positive")
    socket_path = pathlib.Path(args.socket)
    socket_path.parent.mkdir(parents=True, exist_ok=True)
    socket_path.unlink(missing_ok=True)
    scheduler = Scheduler(args.pool, args.capacity, args.state_dir)
    server = Server(str(socket_path), Handler)
    server.scheduler = scheduler
    os.chmod(socket_path, 0o660)
    pathlib.Path(args.pid_file).write_text(str(os.getpid()) + "\n")
    stopping = threading.Event()

    def request_stop(_signum, _frame):
        stopping.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    scheduler.start()
    try:
        server.serve_forever(poll_interval=0.1)
    finally:
        scheduler.stop()
        server.server_close()
        socket_path.unlink(missing_ok=True)
        pathlib.Path(args.pid_file).unlink(missing_ok=True)


if __name__ == "__main__":
    main()
