#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import signal
import time
import urllib.error
import urllib.request


release_requested = False


def on_release(signum, frame):
    global release_requested
    release_requested = True


def request(endpoint, method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(endpoint + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=3) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as exc:
        raise RuntimeError(exc.read().decode(errors="replace")) from exc


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--context", required=True)
    parser.add_argument("--change", required=True)
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("--run-id-file", required=True)
    args = parser.parse_args()
    cfg = json.loads(pathlib.Path(args.context).read_text())
    change_path = pathlib.Path(args.change)
    raw = change_path.read_bytes()
    change = json.loads(raw)
    pathlib.Path(args.pid_file).write_text(str(os.getpid()) + "\n")
    signal.signal(signal.SIGUSR1, on_release)
    run = request(cfg["endpoint"], "POST", "/api/runs", {
        "change_id": change["change_id"],
        "description": change["description"],
        "operation": change["operation"],
        "desired_outputs": change["desired_outputs"],
        "config_sha256": hashlib.sha256(raw).hexdigest(),
        "lineage": cfg["lineage"],
        "kind": "incumbent",
        "executor_pid": os.getpid(),
    })
    pathlib.Path(args.run_id_file).write_text(run["id"] + "\n")
    if run["status"] != "applying":
        raise SystemExit("incumbent did not receive the writer slot")
    phases = change.get("progress_phases") or ["provider_refresh", "provider_apply", "health_validation"]
    step = 0
    while True:
        current = request(cfg["endpoint"], "GET", f'/api/runs/{run["id"]}')
        if current["status"] == "canceled":
            raise SystemExit(20)
        if current["status"] != "applying":
            raise SystemExit(0 if current["status"] == "applied" else 21)
        if release_requested:
            request(cfg["endpoint"], "POST", f'/api/runs/{run["id"]}/commit', {})
            raise SystemExit(0)
        step += 1
        phase = phases[(step - 1) % len(phases)]
        request(cfg["endpoint"], "POST", f'/api/runs/{run["id"]}/progress', {
            "phase": phase,
            "step": step,
            "detail": {"validated_units": step * 3, "apply_checksum": hashlib.sha256(f"{run['id']}:{step}".encode()).hexdigest()[:16]},
        })
        time.sleep(0.25)


if __name__ == "__main__":
    main()
