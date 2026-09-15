#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import sys
import time
import urllib.error
import urllib.request


CONTEXT = pathlib.Path(os.environ.get("REMOTEIAC_CONTEXT", "/etc/remoteiac/context.json"))


def context():
    return json.loads(CONTEXT.read_text())


def request(method, path, body=None):
    cfg = context()
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(cfg["endpoint"] + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=3) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as exc:
        message = exc.read().decode(errors="replace")
        raise RuntimeError(f"remote workspace request failed ({exc.code}): {message}") from exc


def run_list(as_json):
    payload = request("GET", "/api/runs")
    if as_json:
        print(json.dumps(payload, indent=2, sort_keys=True))
        return 0
    for run in payload["runs"]:
        predecessor = run.get("predecessor_run_id") or "-"
        print(f'{run["id"]}\t{run["status"]}\t{run["change_id"]}\tpredecessor={predecessor}')
    return 0


def apply_change(args):
    cfg = context()
    change_path = pathlib.Path(args.change)
    raw = change_path.read_bytes()
    change = json.loads(raw)
    body = {
        "change_id": change["change_id"],
        "description": change["description"],
        "operation": change["operation"],
        "desired_outputs": change["desired_outputs"],
        "config_sha256": hashlib.sha256(raw).hexdigest(),
        "lineage": cfg["lineage"],
        "kind": "requested",
        "executor_pid": os.getpid(),
    }
    run = request("POST", "/api/runs", body)
    run_id = run["id"]
    print(f"submitted {run_id} status={run['status']} change={run['change_id']}", flush=True)
    deadline = time.monotonic() + args.wait
    while time.monotonic() < deadline:
        run = request("GET", f"/api/runs/{run_id}")
        if run["status"] == "applying":
            phases = change.get("progress_phases") or ["configuration_upload", "plan", "apply"]
            for step, phase in enumerate(phases, 1):
                request("POST", f"/api/runs/{run_id}/progress", {
                    "phase": phase, "step": step, "detail": {"change_id": change["change_id"]}
                })
                time.sleep(0.12)
            result = request("POST", f"/api/runs/{run_id}/commit", {})
            receipt = {
                "workspace": cfg["workspace"],
                "run_id": run_id,
                "change_id": change["change_id"],
                "status": result["run"]["status"],
                "state_version_id": result["state_version"]["id"],
                "serial": result["state_version"]["serial"],
                "lineage": result["state_version"]["lineage"],
                "outputs": result["state_version"]["outputs"],
            }
            receipt_path = pathlib.Path(args.receipt)
            receipt_path.parent.mkdir(parents=True, exist_ok=True)
            receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
            print(f"applied {run_id} state_version={receipt['state_version_id']} serial={receipt['serial']}")
            return 0
        if run["status"] in {"canceled", "errored", "applied"}:
            print(f"run {run_id} ended with status={run['status']}", file=sys.stderr)
            return 1
        time.sleep(0.2)
    run = request("GET", f"/api/runs/{run_id}")
    if run["status"] == "queued":
        request("POST", f"/api/runs/{run_id}/cancel", {})
    print(f"run {run_id} did not receive the writer slot within {args.wait:g}s; final_status={run['status']}", file=sys.stderr)
    return 75


def main():
    parser = argparse.ArgumentParser(prog="tfremote")
    sub = parser.add_subparsers(dest="group", required=True)
    workspace = sub.add_parser("workspace")
    workspace_sub = workspace.add_subparsers(dest="action", required=True)
    workspace_sub.add_parser("show")
    runs = sub.add_parser("runs")
    runs_sub = runs.add_subparsers(dest="action", required=True)
    listing = runs_sub.add_parser("list")
    listing.add_argument("--json", action="store_true")
    show = runs_sub.add_parser("show")
    show.add_argument("run_id")
    cancel = runs_sub.add_parser("cancel")
    cancel.add_argument("run_id")
    apply_parser = runs_sub.add_parser("apply")
    apply_parser.add_argument("--change", required=True)
    apply_parser.add_argument("--receipt", required=True)
    apply_parser.add_argument("--wait", type=float, default=12)
    args = parser.parse_args()
    if args.group == "workspace":
        print(json.dumps(request("GET", "/api/workspace"), indent=2, sort_keys=True))
        return
    if args.action == "list":
        raise SystemExit(run_list(args.json))
    if args.action == "show":
        print(json.dumps(request("GET", f"/api/runs/{args.run_id}"), indent=2, sort_keys=True))
        return
    if args.action == "cancel":
        print(json.dumps(request("POST", f"/api/runs/{args.run_id}/cancel", {}), indent=2, sort_keys=True))
        return
    raise SystemExit(apply_change(args))


if __name__ == "__main__":
    main()
