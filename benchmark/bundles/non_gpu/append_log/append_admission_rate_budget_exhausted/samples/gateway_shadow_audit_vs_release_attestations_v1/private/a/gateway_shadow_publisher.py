#!/usr/bin/env python3
import argparse
import hashlib
import http.client
import json
import os
import pathlib
import signal
import socket
import time


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def sha256(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


class Publisher:
    def __init__(self, args):
        self.args = args
        self.routes = json.loads(pathlib.Path(args.routes).read_text())
        self.token = pathlib.Path(args.token_file).read_text().strip()
        self.progress_path = pathlib.Path(args.progress)
        self.receipts_path = pathlib.Path(args.receipts)
        self.receipts_path.parent.mkdir(parents=True, exist_ok=True)
        self.receipts = self.receipts_path.open("a", buffering=1)
        self.stop = False
        self.started_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        self.fixture_sha256 = sha256(args.routes)
        self.attempted = 0
        self.admitted = 0
        self.throttled = 0
        self.errors = 0
        self.route_counts = {}
        self.decision_counts = {}
        self.latest_sequence = None
        self.connection = None

    def close_connection(self):
        if self.connection is not None:
            try:
                self.connection.close()
            except Exception:
                pass
        self.connection = None

    def request(self, payload):
        body = (canonical(payload) + "\n").encode()
        for _ in range(2):
            try:
                if self.connection is None:
                    self.connection = http.client.HTTPConnection("127.0.0.1", 43871, timeout=1.0)
                    self.connection.connect()
                    self.connection.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                self.connection.request(
                    "POST",
                    "/append",
                    body=body,
                    headers={"Content-Type": "application/json", "Authorization": f"Bearer {self.token}"},
                )
                response = self.connection.getresponse()
                data = json.loads(response.read().decode())
                return response.status, data
            except Exception:
                self.close_connection()
        raise ConnectionError("collector request failed after reconnect")

    def event(self, index):
        routes = self.routes["routes"]
        decisions = self.routes["decision_classes"]
        route = routes[index % len(routes)]
        decision = decisions[(index * 3) % len(decisions)]
        return {
            "owner": self.args.owner,
            "client_id": self.args.client_id,
            "transaction": "candidate-policy-shadow-stream",
            "stream": "gateway-shadow-access-decisions",
            "event_id": f"shadow-{index:09d}",
            "event_type": "gateway_shadow_decision",
            "payload": {
                "policy_generation": self.routes["policy_generation"],
                "route_id": route["route_id"],
                "method": route["method"],
                "required_scope": route["scope"],
                "identity_class": f"service-tier-{index % 11:02d}",
                "decision_class": decision,
                "request_digest": hashlib.sha256(f"request-{index}".encode()).hexdigest(),
                "shadow_latency_ms": 2 + (index % 17),
            },
        }

    def write_progress(self):
        payload = {
            "pid": os.getpid(),
            "started_at": self.started_at,
            "owner": self.args.owner,
            "client_id": self.args.client_id,
            "policy_generation": self.routes["policy_generation"],
            "routes_sha256": self.fixture_sha256,
            "attempted_events": self.attempted,
            "admitted_events": self.admitted,
            "throttled_events": self.throttled,
            "error_count": self.errors,
            "latest_sequence": self.latest_sequence,
            "route_counts": dict(sorted(self.route_counts.items())),
            "decision_counts": dict(sorted(self.decision_counts.items())),
            "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        }
        tmp = self.progress_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
        tmp.replace(self.progress_path)

    def run(self):
        signal.signal(signal.SIGTERM, lambda *_: setattr(self, "stop", True))
        signal.signal(signal.SIGINT, lambda *_: setattr(self, "stop", True))
        interval = 1.0 / self.args.attempt_eps
        next_send = time.monotonic()
        self.write_progress()
        while not self.stop:
            delay = next_send - time.monotonic()
            if delay > 0:
                time.sleep(min(delay, 0.005))
                continue
            self.attempted += 1
            item = self.event(self.attempted)
            try:
                code, response = self.request(item)
                if code == 200 and response.get("status") == "ADMITTED":
                    self.admitted += 1
                    self.latest_sequence = response.get("sequence")
                    route = item["payload"]["route_id"]
                    decision = item["payload"]["decision_class"]
                    self.route_counts[route] = self.route_counts.get(route, 0) + 1
                    self.decision_counts[decision] = self.decision_counts.get(decision, 0) + 1
                    self.receipts.write(json.dumps({
                        "event_id": item["event_id"],
                        "sequence": response.get("sequence"),
                        "durable_offset": response.get("durable_offset"),
                        "route_id": route,
                        "decision_class": decision,
                    }, sort_keys=True) + "\n")
                elif code == 429:
                    self.throttled += 1
                else:
                    self.errors += 1
            except Exception:
                self.errors += 1
            if self.attempted % 12 == 0:
                self.write_progress()
            next_send += interval
            if next_send < time.monotonic() - 0.15:
                next_send = time.monotonic()
        self.write_progress()
        self.receipts.close()
        self.close_connection()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--collector", required=True)
    parser.add_argument("--token-file", required=True)
    parser.add_argument("--routes", required=True)
    parser.add_argument("--progress", required=True)
    parser.add_argument("--receipts", required=True)
    parser.add_argument("--owner", required=True)
    parser.add_argument("--client-id", required=True)
    parser.add_argument("--attempt-eps", required=True, type=float)
    Publisher(parser.parse_args()).run()


if __name__ == "__main__":
    main()
