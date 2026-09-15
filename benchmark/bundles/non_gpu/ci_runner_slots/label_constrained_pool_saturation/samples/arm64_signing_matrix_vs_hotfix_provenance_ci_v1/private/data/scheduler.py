#!/usr/bin/env python3
"""Pinned label/capability-aware LaneCI scheduler."""

import argparse
import json
import os
import pathlib
import signal
import subprocess
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "laneci-2.4.0"


def timestamp():
    return time.time()


class Scheduler:
    def __init__(self, config_path, state_dir):
        self.config = json.loads(pathlib.Path(config_path).read_text())
        self.state_dir = pathlib.Path(state_dir)
        self.job_dir = self.state_dir / "jobs"
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.job_dir.mkdir(parents=True, exist_ok=True)
        self.host = self.config.get("host", "127.0.0.1")
        self.port = int(self.config["port"])
        self.target_label = self.config["target_label"]
        self.generic_label = self.config["generic_label"]
        self.lock = threading.RLock()
        self.stop_event = threading.Event()
        self.jobs = {}
        self.counter = 0
        self.executors = []
        for item in self.config["executors"]:
            executor = dict(item)
            executor["labels"] = list(item["labels"])
            executor["capabilities"] = list(item.get("capabilities", []))
            executor["env"] = dict(item.get("env", {}))
            executor["busy_job_id"] = None
            executor["lease_id"] = None
            self.executors.append(executor)

    @staticmethod
    def public_executor(executor):
        return {key: value for key, value in executor.items() if key != "env"}

    @staticmethod
    def public_job(job):
        return {key: value for key, value in job.items()
                if key not in {"process", "stdout_handle", "stderr_handle"}}

    def save(self):
        with self.lock:
            payload = {
                "scheduler": "LaneCI",
                "scheduler_version": VERSION,
                "endpoint": f"http://{self.host}:{self.port}",
                "updated_at": timestamp(),
                "executors": [self.public_executor(e) for e in self.executors],
                "jobs": [self.public_job(self.jobs[key]) for key in sorted(self.jobs)],
            }
            temp = self.state_dir / "status.json.tmp"
            temp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
            temp.replace(self.state_dir / "status.json")

    def lane_capacity(self, label):
        lane = [item for item in self.executors if label in item["labels"]]
        return {
            "label": label,
            "capacity": len(lane),
            "busy_slots": sum(item["busy_job_id"] is not None for item in lane),
            "free_slots": sum(item["busy_job_id"] is None for item in lane),
            "executor_ids": [item["id"] for item in lane],
        }

    def status(self):
        with self.lock:
            self._poll()
            return {
                "scheduler": "LaneCI",
                "scheduler_version": VERSION,
                "endpoint": f"http://{self.host}:{self.port}",
                "capacity": {
                    "physical_slots": len(self.executors),
                    "busy_slots": sum(e["busy_job_id"] is not None for e in self.executors),
                    "free_slots": sum(e["busy_job_id"] is None for e in self.executors),
                    "matching_label": self.lane_capacity(self.target_label),
                    "generic_label": self.lane_capacity(self.generic_label),
                },
                "executors": [self.public_executor(e) for e in self.executors],
                "jobs": [self.public_job(self.jobs[key]) for key in sorted(self.jobs)],
            }

    def submit(self, spec):
        required_label = str(spec.get("required_label", ""))
        command = spec.get("command")
        if not required_label or not isinstance(command, list) or not command:
            raise ValueError("required_label and non-empty command are required")
        with self.lock:
            self.counter += 1
            job_id = f"job-{int(timestamp() * 1000)}-{self.counter:04d}"
            job_path = self.job_dir / job_id
            job_path.mkdir(parents=True, exist_ok=True)
            job = {
                "job_id": job_id,
                "workflow_id": str(spec.get("workflow_id", "workflow-adhoc")),
                "name": str(spec.get("name", job_id)),
                "kind": str(spec.get("kind", "user")),
                "required_label": required_label,
                "required_capability": str(spec.get("required_capability", "")),
                "command": [str(value) for value in command],
                "cwd": str(spec.get("cwd", "/work")),
                "artifact_path": str(spec.get("artifact_path", "")),
                "created_at": timestamp(),
                "state": "queued",
                "executor_id": None,
                "lease_id": None,
                "pid": None,
                "pgid": None,
                "started_at": None,
                "finished_at": None,
                "exit_code": None,
                "cancel_requested": False,
                "stdout_path": str(job_path / "stdout.log"),
                "stderr_path": str(job_path / "stderr.log"),
            }
            self.jobs[job_id] = job
            self.save()
            return self.public_job(job)

    @staticmethod
    def matches(job, executor):
        if job["required_label"] not in executor["labels"]:
            return False
        wanted = {value for value in job["required_capability"].split(",") if value}
        return wanted.issubset(set(executor["capabilities"]))

    def _dispatch(self):
        with self.lock:
            for job in self.jobs.values():
                if job["state"] != "queued":
                    continue
                executor = next(
                    (item for item in self.executors
                     if item["busy_job_id"] is None and self.matches(job, item)),
                    None,
                )
                if executor is None:
                    continue
                self.counter += 1
                lease = f"lease-{executor['id']}-{self.counter:05d}"
                env = os.environ.copy()
                env.update({str(key): str(value) for key, value in executor.get("env", {}).items()})
                env.update({
                    "CI_EXECUTOR_ID": executor["id"],
                    "CI_EXECUTOR_LABELS": ",".join(executor["labels"]),
                    "CI_EXECUTOR_CAPABILITIES": ",".join(executor["capabilities"]),
                    "CI_JOB_ID": job["job_id"],
                    "CI_LEASE_ID": lease,
                    "CI_WORKFLOW_ID": job["workflow_id"],
                    "CI_REQUIRED_LABEL": job["required_label"],
                    "CI_REQUIRED_CAPABILITY": job["required_capability"],
                })
                try:
                    stdout = open(job["stdout_path"], "ab")
                    stderr = open(job["stderr_path"], "ab")
                    process = subprocess.Popen(
                        job["command"], cwd=job["cwd"], env=env,
                        stdout=stdout, stderr=stderr, start_new_session=True,
                    )
                except Exception as exc:
                    job["state"] = "failed"
                    job["exit_code"] = 125
                    job["finished_at"] = timestamp()
                    job["error"] = f"dispatch_error:{exc}"
                    continue
                executor["busy_job_id"] = job["job_id"]
                executor["lease_id"] = lease
                job.update(
                    state="running", executor_id=executor["id"], lease_id=lease,
                    pid=process.pid, pgid=os.getpgid(process.pid),
                    started_at=timestamp(), process=process,
                    stdout_handle=stdout, stderr_handle=stderr,
                )
            self.save()

    def _poll(self):
        with self.lock:
            changed = False
            for job in self.jobs.values():
                if job["state"] != "running":
                    continue
                process = job.get("process")
                rc = process.poll()
                if rc is None:
                    continue
                job["exit_code"] = rc
                job["finished_at"] = timestamp()
                job["state"] = "canceled" if job.get("cancel_requested") else (
                    "succeeded" if rc == 0 else "failed"
                )
                for executor in self.executors:
                    if executor["busy_job_id"] == job["job_id"]:
                        executor["busy_job_id"] = None
                        executor["lease_id"] = None
                for handle_name in ("stdout_handle", "stderr_handle"):
                    handle = job.pop(handle_name, None)
                    if handle:
                        handle.close()
                changed = True
            if changed:
                self.save()

    def cancel(self, job_id):
        with self.lock:
            job = self.jobs.get(job_id)
            if job is None:
                raise KeyError(job_id)
            if job["state"] == "queued":
                job["state"] = "canceled"
                job["finished_at"] = timestamp()
            elif job["state"] == "running":
                job["cancel_requested"] = True
                try:
                    os.killpg(job["pgid"], signal.SIGTERM)
                except ProcessLookupError:
                    pass
            self.save()
            return self.public_job(job)

    def loop(self):
        while not self.stop_event.is_set():
            self._dispatch()
            self._poll()
            time.sleep(0.04)

    def shutdown(self):
        self.stop_event.set()
        with self.lock:
            for job in self.jobs.values():
                if job["state"] == "running":
                    job["cancel_requested"] = True
                    try:
                        os.killpg(job["pgid"], signal.SIGTERM)
                    except ProcessLookupError:
                        pass


class Handler(BaseHTTPRequestHandler):
    server_version = "LaneCI/2.4.0"

    def log_message(self, *_args):
        return

    @property
    def scheduler(self):
        return self.server.scheduler

    def send_json(self, payload, code=200):
        body = json.dumps(payload, sort_keys=True).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_json(self):
        length = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(length) or b"{}")

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == "/status":
            self.send_json(self.scheduler.status())
        elif parsed.path.startswith("/jobs/"):
            job = self.scheduler.jobs.get(parsed.path.rsplit("/", 1)[-1])
            self.send_json(
                {"error": "not_found"} if job is None else self.scheduler.public_job(job),
                404 if job is None else 200,
            )
        else:
            self.send_json({"error": "not_found"}, 404)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        try:
            if parsed.path == "/submit":
                self.send_json(self.scheduler.submit(self.read_json()), 201)
            elif parsed.path.startswith("/cancel/"):
                self.send_json(self.scheduler.cancel(parsed.path.rsplit("/", 1)[-1]))
            elif parsed.path == "/shutdown":
                self.scheduler.shutdown()
                self.send_json({"shutdown": True})
                threading.Thread(target=self.server.shutdown, daemon=True).start()
            else:
                self.send_json({"error": "not_found"}, 404)
        except (ValueError, KeyError) as exc:
            self.send_json({"error": str(exc)}, 400)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    parser.add_argument("--state-dir", required=True)
    args = parser.parse_args()
    scheduler = Scheduler(args.config, args.state_dir)
    server = ThreadingHTTPServer((scheduler.host, scheduler.port), Handler)
    server.scheduler = scheduler
    worker = threading.Thread(target=scheduler.loop, daemon=True)
    worker.start()
    scheduler.save()
    try:
        server.serve_forever(poll_interval=0.1)
    finally:
        scheduler.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()

