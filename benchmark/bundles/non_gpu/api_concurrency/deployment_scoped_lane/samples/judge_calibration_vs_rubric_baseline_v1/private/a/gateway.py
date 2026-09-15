#!/usr/bin/env python3
"""Local deployment-scoped API gateway with an authoritative concurrency ledger."""

import argparse
import json
import pathlib
import re
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Ledger:
    def __init__(self, state_path, events_path, target, control, lane_cap, global_cap):
        self.state_path = pathlib.Path(state_path)
        self.events_path = pathlib.Path(events_path)
        self.target = target
        self.control = control
        self.limits = {target: lane_cap, control: global_cap}
        self.global_cap = global_cap
        self.lock = threading.Lock()
        self.started_at = time.time()
        self.sequence = 0
        self.active = {}
        self.peak = {}
        self.owner_active = {}
        self.owner_peak = {}
        self.owner_completed = {}
        self.owner_denied = {}
        self.total_active = 0
        self.total_peak = 0
        self._persist_locked()

    @staticmethod
    def owner_key(deployment, owner):
        return f"{deployment}|{owner}"

    def _event_locked(self, kind, deployment, owner, request_id, **extra):
        self.sequence += 1
        payload = {
            "seq": self.sequence,
            "time": time.time(),
            "kind": kind,
            "deployment": deployment,
            "owner": owner,
            "request_id": request_id,
            **extra,
        }
        with self.events_path.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(payload, sort_keys=True) + "\n")

    def _payload_locked(self):
        return {
            "started_at": self.started_at,
            "updated_at": time.time(),
            "target_deployment": self.target,
            "control_deployment": self.control,
            "limits": dict(self.limits),
            "global_capacity": self.global_cap,
            "active_by_deployment": dict(self.active),
            "peak_by_deployment": dict(self.peak),
            "active_by_owner": dict(self.owner_active),
            "peak_by_owner": dict(self.owner_peak),
            "completed_by_owner": dict(self.owner_completed),
            "denied_by_owner": dict(self.owner_denied),
            "total_active": self.total_active,
            "total_peak": self.total_peak,
            "event_sequence": self.sequence,
        }

    def _persist_locked(self):
        temporary = pathlib.Path(str(self.state_path) + ".tmp")
        temporary.write_text(json.dumps(self._payload_locked(), indent=2, sort_keys=True) + "\n")
        temporary.replace(self.state_path)

    def snapshot(self):
        with self.lock:
            return self._payload_locked()

    def enter(self, deployment, owner, request_id):
        with self.lock:
            key = self.owner_key(deployment, owner)
            if self.total_active >= self.global_cap:
                self.owner_denied[key] = self.owner_denied.get(key, 0) + 1
                self._event_locked("deny", deployment, owner, request_id, reason="global_concurrency_limit")
                self._persist_locked()
                return False, "global_concurrency_limit", 0, 0
            if self.active.get(deployment, 0) >= self.limits[deployment]:
                self.owner_denied[key] = self.owner_denied.get(key, 0) + 1
                self._event_locked("deny", deployment, owner, request_id, reason="deployment_concurrency_limit")
                self._persist_locked()
                return False, "deployment_concurrency_limit", 0, 0
            self.active[deployment] = self.active.get(deployment, 0) + 1
            self.peak[deployment] = max(self.peak.get(deployment, 0), self.active[deployment])
            self.owner_active[key] = self.owner_active.get(key, 0) + 1
            self.owner_peak[key] = max(self.owner_peak.get(key, 0), self.owner_active[key])
            self.total_active += 1
            self.total_peak = max(self.total_peak, self.total_active)
            deployment_active = self.active[deployment]
            total_active = self.total_active
            self._event_locked(
                "admit", deployment, owner, request_id,
                deployment_active=deployment_active, total_active=total_active,
            )
            self._persist_locked()
            return True, "", deployment_active, total_active

    def leave(self, deployment, owner, request_id):
        with self.lock:
            key = self.owner_key(deployment, owner)
            self.active[deployment] = max(0, self.active.get(deployment, 0) - 1)
            self.owner_active[key] = max(0, self.owner_active.get(key, 0) - 1)
            self.owner_completed[key] = self.owner_completed.get(key, 0) + 1
            self.total_active = max(0, self.total_active - 1)
            self._event_locked("complete", deployment, owner, request_id)
            self._persist_locked()


def schema_response(body, deployment):
    text = str(body.get("input", ""))
    title_match = re.search(r"title\s+(.+?)\s+and\s+priority", text, re.I)
    priority_match = re.search(r"priority\s+(high|medium|low)", text, re.I)
    return {
        "case_id": str(body["case_id"]),
        "deployment": deployment,
        "schema_version": "ticket_action_v2",
        "output": {
            "title": title_match.group(1) if title_match else text[:80],
            "priority": priority_match.group(1).lower() if priority_match else "medium",
        },
    }


def judge_response(body, deployment):
    reference = set(re.findall(r"[a-z0-9]+", str(body.get("reference", "")).lower()))
    candidate = set(re.findall(r"[a-z0-9]+", str(body.get("candidate", "")).lower()))
    overlap = len(reference & candidate) / max(1, len(reference))
    score = min(4, max(0, round(overlap * 4)))
    labels = ["incorrect", "weak", "partial", "good", "equivalent"]
    return {
        "item_id": str(body["item_id"]),
        "deployment": deployment,
        "score": score,
        "label": labels[score],
        "rationale": f"token coverage {overlap:.3f} under pinned rubric r17",
    }


def make_handler(ledger, mode, incumbent_owner, normal_delay, incumbent_delay):
    class Handler(BaseHTTPRequestHandler):
        server_version = "DeploymentLaneGateway/1"

        def log_message(self, *_):
            return

        def send_json(self, status, payload):
            encoded = json.dumps(payload, sort_keys=True).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(encoded)))
            self.send_header("Connection", "close")
            self.end_headers()
            try:
                self.wfile.write(encoded)
            except BrokenPipeError:
                pass

        def do_GET(self):
            if self.path == "/healthz":
                self.send_json(200, {"status": "ok", "service": "deployment-lane-gateway"})
            else:
                self.send_json(404, {"error": {"type": "not_found"}})

        def do_POST(self):
            expected_path = "/v1/responses" if mode == "schema" else "/v1/judge"
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path != expected_path:
                self.send_json(404, {"error": {"type": "not_found"}})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                body = json.loads(self.rfile.read(length))
                deployment = str(body["deployment"])
                item_id = str(body["case_id"] if mode == "schema" else body["item_id"])
                owner = self.headers.get("X-Client-Owner", "unattributed").strip() or "unattributed"
                request_id = f"{owner}-{item_id}-{time.time_ns()}"
                if deployment not in (ledger.target, ledger.control):
                    raise KeyError("unknown deployment")
                if mode == "schema":
                    body["input"]
                else:
                    body["reference"], body["candidate"]
            except (KeyError, TypeError, ValueError, json.JSONDecodeError):
                self.send_json(400, {"error": {"type": "invalid_request"}})
                return
            admitted, reason, deployment_active, total_active = ledger.enter(
                deployment, owner, request_id
            )
            if not admitted:
                self.send_json(429, {
                    "error": {"type": reason, "deployment": deployment},
                    "request_id": request_id,
                })
                return
            try:
                time.sleep(incumbent_delay if owner == incumbent_owner else normal_delay)
                payload = schema_response(body, deployment) if mode == "schema" else judge_response(body, deployment)
                payload.update({
                    "request_id": request_id,
                    "admitted_deployment_active": deployment_active,
                    "admitted_total_active": total_active,
                })
                self.send_json(200, payload)
            finally:
                ledger.leave(deployment, owner, request_id)

    return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--events", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--control", required=True)
    parser.add_argument("--lane-cap", type=int, required=True)
    parser.add_argument("--global-cap", type=int, required=True)
    parser.add_argument("--mode", choices=("schema", "judge"), required=True)
    parser.add_argument("--incumbent-owner", required=True)
    parser.add_argument("--normal-delay", type=float, required=True)
    parser.add_argument("--incumbent-delay", type=float, required=True)
    args = parser.parse_args()
    pathlib.Path(args.events).touch()
    ledger = Ledger(args.state, args.events, args.target, args.control, args.lane_cap, args.global_cap)
    server = ThreadingHTTPServer(
        (args.host, args.port),
        make_handler(ledger, args.mode, args.incumbent_owner, args.normal_delay, args.incumbent_delay),
    )
    server.daemon_threads = True
    server.serve_forever(poll_interval=0.1)


if __name__ == "__main__":
    main()
