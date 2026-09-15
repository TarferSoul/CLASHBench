#!/usr/bin/env python3
import argparse
import json
import pathlib
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse


def read_json(path):
    return json.loads(pathlib.Path(path).read_text())


def atomic_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = pathlib.Path(str(path) + ".tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    tmp.replace(path)


def initial_state(config):
    workspace = config["workspace"]
    serial = int(workspace["baseline_serial"])
    version_id = f'{workspace["state_prefix"]}-{serial:04d}'
    now = time.time()
    return {
        "workspace_id": workspace["id"],
        "workspace_name": workspace["name"],
        "lineage": workspace["lineage"],
        "serial": serial,
        "current_state_version_id": version_id,
        "active_run_id": None,
        "next_run_number": 1,
        "next_event_sequence": 1,
        "runs": [],
        "events": [],
        "state_versions": [{
            "id": version_id,
            "serial": serial,
            "lineage": workspace["lineage"],
            "run_id": "seed",
            "change_id": "baseline",
            "outputs": workspace["baseline_outputs"],
            "created_at": now,
        }],
    }


class Store:
    def __init__(self, config, state_path):
        self.config = config
        self.state_path = pathlib.Path(state_path)
        self.lock = threading.RLock()
        self.state = read_json(self.state_path)

    def save(self):
        atomic_json(self.state_path, self.state)

    def event(self, event_type, run_id, **details):
        seq = self.state["next_event_sequence"]
        self.state["next_event_sequence"] += 1
        event = {"sequence": seq, "type": event_type, "run_id": run_id, "at": time.time()}
        event.update(details)
        self.state["events"].append(event)
        return seq

    def find_run(self, run_id):
        return next((item for item in self.state["runs"] if item["id"] == run_id), None)

    def promote(self):
        queued = next((item for item in self.state["runs"] if item["status"] == "queued"), None)
        if queued is None:
            self.state["active_run_id"] = None
            return
        queued["status"] = "applying"
        queued["apply_started_at"] = time.time()
        queued["apply_started_seq"] = self.event("apply_started", queued["id"], after_run_id=queued["predecessor_run_id"])
        self.state["active_run_id"] = queued["id"]

    def submit(self, body):
        required = ("change_id", "description", "operation", "desired_outputs", "config_sha256")
        missing = [key for key in required if key not in body]
        if missing:
            raise ValueError("missing fields: " + ",".join(missing))
        if body.get("lineage") != self.state["lineage"]:
            raise ValueError("lineage mismatch")
        number = self.state["next_run_number"]
        self.state["next_run_number"] += 1
        run_id = f'{self.config["workspace"]["run_prefix"]}-{number:04d}'
        predecessor = self.state["active_run_id"]
        status = "queued" if predecessor else "applying"
        now = time.time()
        run = {
            "id": run_id,
            "workspace_id": self.state["workspace_id"],
            "change_id": str(body["change_id"]),
            "description": str(body["description"]),
            "operation": str(body["operation"]),
            "desired_outputs": body["desired_outputs"],
            "config_sha256": str(body["config_sha256"]),
            "kind": str(body.get("kind") or "requested"),
            "status": status,
            "predecessor_run_id": predecessor,
            "submitted_at": now,
            "submitted_seq": self.event("run_submitted", run_id, predecessor_run_id=predecessor),
            "apply_started_at": None,
            "apply_started_seq": None,
            "progress_count": 0,
            "last_progress": None,
            "last_heartbeat": None,
            "executor_pid_claim": body.get("executor_pid"),
        }
        self.state["runs"].append(run)
        if status == "applying":
            run["apply_started_at"] = now
            run["apply_started_seq"] = self.event("apply_started", run_id, after_run_id=None)
            self.state["active_run_id"] = run_id
        self.save()
        return run

    def progress(self, run_id, body):
        run = self.find_run(run_id)
        if run is None:
            raise KeyError(run_id)
        if run["status"] != "applying" or self.state["active_run_id"] != run_id:
            raise ValueError("run does not own the workspace writer")
        run["progress_count"] += 1
        run["last_heartbeat"] = time.time()
        run["last_progress"] = {
            "phase": str(body.get("phase") or "provider_apply"),
            "step": int(body.get("step") or run["progress_count"]),
            "detail": body.get("detail") or {},
        }
        if run["progress_count"] == 1 or run["progress_count"] % 10 == 0:
            self.event("apply_progress", run_id, progress_count=run["progress_count"], phase=run["last_progress"]["phase"])
        self.save()
        return run

    def commit(self, run_id):
        run = self.find_run(run_id)
        if run is None:
            raise KeyError(run_id)
        if run["status"] != "applying" or self.state["active_run_id"] != run_id:
            raise ValueError("run does not own the workspace writer")
        previous = dict(self.state["state_versions"][-1]["outputs"])
        previous.update(run["desired_outputs"])
        self.state["serial"] += 1
        serial = self.state["serial"]
        version_id = f'{self.config["workspace"]["state_prefix"]}-{serial:04d}'
        version = {
            "id": version_id,
            "serial": serial,
            "lineage": self.state["lineage"],
            "run_id": run_id,
            "change_id": run["change_id"],
            "outputs": previous,
            "created_at": time.time(),
        }
        self.state["state_versions"].append(version)
        self.state["current_state_version_id"] = version_id
        run["status"] = "applied"
        run["applied_at"] = time.time()
        run["state_version_id"] = version_id
        run["applied_seq"] = self.event("state_version_published", run_id, state_version_id=version_id, serial=serial)
        self.state["active_run_id"] = None
        self.promote()
        self.save()
        return {"run": run, "state_version": version}

    def cancel(self, run_id):
        run = self.find_run(run_id)
        if run is None:
            raise KeyError(run_id)
        if run["status"] not in {"queued", "applying"}:
            return run
        was_active = self.state["active_run_id"] == run_id
        run["status"] = "canceled"
        run["canceled_at"] = time.time()
        run["canceled_seq"] = self.event("run_canceled", run_id, was_active=was_active)
        if was_active:
            self.state["active_run_id"] = None
            self.promote()
        self.save()
        return run


class Handler(BaseHTTPRequestHandler):
    server_version = "RemoteIaCWorkspace/2.3"

    def log_message(self, fmt, *args):
        return

    def send_json(self, status, value):
        payload = json.dumps(value, sort_keys=True).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def body(self):
        length = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(length) or b"{}")

    def do_GET(self):
        path = urlparse(self.path).path
        store = self.server.store
        with store.lock:
            if path == "/health":
                return self.send_json(200, {"ok": True, "workspace_id": store.state["workspace_id"]})
            if path == "/api/workspace":
                keys = ("workspace_id", "workspace_name", "lineage", "serial", "current_state_version_id", "active_run_id")
                return self.send_json(200, {key: store.state[key] for key in keys})
            if path == "/api/runs":
                return self.send_json(200, {"runs": store.state["runs"]})
            if path.startswith("/api/runs/"):
                run_id = path.split("/")[3]
                run = store.find_run(run_id)
                return self.send_json(200 if run else 404, run or {"error": "run not found"})
            if path == "/api/state-versions":
                return self.send_json(200, {"state_versions": store.state["state_versions"]})
        self.send_json(404, {"error": "not found"})

    def do_POST(self):
        path = urlparse(self.path).path
        store = self.server.store
        try:
            body = self.body()
            with store.lock:
                if path == "/api/runs":
                    return self.send_json(201, store.submit(body))
                parts = path.strip("/").split("/")
                if len(parts) == 4 and parts[:2] == ["api", "runs"]:
                    run_id, action = parts[2], parts[3]
                    if action == "progress":
                        return self.send_json(200, store.progress(run_id, body))
                    if action == "commit":
                        return self.send_json(200, store.commit(run_id))
                    if action == "cancel":
                        return self.send_json(200, store.cancel(run_id))
            self.send_json(404, {"error": "not found"})
        except KeyError as exc:
            self.send_json(404, {"error": f"run not found: {exc}"})
        except (ValueError, json.JSONDecodeError) as exc:
            self.send_json(409, {"error": str(exc)})


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    reset = sub.add_parser("reset")
    reset.add_argument("--config", required=True)
    reset.add_argument("--state-dir", required=True)
    serve = sub.add_parser("serve")
    serve.add_argument("--config", required=True)
    serve.add_argument("--state-dir", required=True)
    serve.add_argument("--port", required=True, type=int)
    dump = sub.add_parser("dump")
    dump.add_argument("--state-dir", required=True)
    args = parser.parse_args()
    state_path = pathlib.Path(args.state_dir) / "workspace_state.json"
    if args.command == "reset":
        atomic_json(state_path, initial_state(read_json(args.config)))
    elif args.command == "dump":
        print(json.dumps(read_json(state_path), indent=2, sort_keys=True))
    else:
        config = read_json(args.config)
        server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
        server.store = Store(config, state_path)
        server.serve_forever(poll_interval=0.1)


if __name__ == "__main__":
    main()
