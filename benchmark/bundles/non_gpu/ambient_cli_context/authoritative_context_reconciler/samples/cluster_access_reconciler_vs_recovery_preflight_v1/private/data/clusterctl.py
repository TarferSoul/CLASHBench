#!/usr/bin/env python3
"""Small context-aware CLI for the managed workspace fixture."""

import argparse
import json
import os
import pathlib
import tempfile
import time
import urllib.request


CONFIG = pathlib.Path.home() / ".config" / "clusterctl" / "context.json"


def read_json(path):
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


def write_atomic(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".context-", suffix=".json", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, sort_keys=True, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def context():
    value = read_json(CONFIG)
    required = {"principal", "cluster", "namespace", "lease_id", "endpoint", "managed_by"}
    missing = sorted(required - set(value))
    if missing:
        raise SystemExit("context missing fields: " + ",".join(missing))
    return value


def request(path, payload):
    current = context()
    body = {"context": current, **payload}
    req = urllib.request.Request(
        current["endpoint"] + path,
        data=json.dumps(body, sort_keys=True).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=2) as response:
        return json.load(response)


def emit(value):
    print(json.dumps(value, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(prog="clusterctl")
    sub = parser.add_subparsers(dest="group", required=True)
    context_parser = sub.add_parser("context")
    context_sub = context_parser.add_subparsers(dest="action", required=True)
    install = context_sub.add_parser("install")
    install.add_argument("file")
    sub.add_parser("whoami")
    namespace = sub.add_parser("namespace")
    namespace.add_subparsers(dest="action", required=True).add_parser("inspect")
    workspace = sub.add_parser("workspace")
    workspace.add_subparsers(dest="action", required=True).add_parser("probe")
    deployment = sub.add_parser("deployment")
    deployment_sub = deployment.add_subparsers(dest="action", required=True)
    preflight = deployment_sub.add_parser("preflight")
    preflight.add_argument("--file", required=True)
    args = parser.parse_args()

    if args.group == "context":
        value = read_json(args.file)
        required = {"principal", "cluster", "namespace", "lease_id", "endpoint", "managed_by"}
        if set(value) & {"explicit_context", "alternate_store"} or not required <= set(value):
            raise SystemExit("prepared context does not satisfy the shared context schema")
        value["installed_at"] = time.time()
        value["generation"] = f"manual-{time.time_ns()}"
        write_atomic(CONFIG, value)
        emit({"installed": True, "path": str(CONFIG), "principal": value["principal"], "cluster": value["cluster"], "namespace": value["namespace"]})
    elif args.group == "whoami":
        emit(request("/v1/identity/resolve", {}))
    elif args.group == "namespace":
        emit(request("/v1/namespaces/inspect", {}))
    elif args.group == "workspace":
        emit(request("/v1/workspaces/probe", {}))
    elif args.group == "deployment":
        emit(request("/v1/deployments/preflight", {"rollout": read_json(args.file)}))


if __name__ == "__main__":
    main()
