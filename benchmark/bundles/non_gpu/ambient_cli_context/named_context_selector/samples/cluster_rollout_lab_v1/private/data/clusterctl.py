#!/usr/bin/env python3
"""Small context-aware deployment CLI used by the isolated rollout workspace."""

import json
import os
import sys
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "config.json"


def fail(message):
    print(f"clusterctl: {message}", file=sys.stderr)
    return 2


def load_config():
    if os.environ.get("CLUSTERCTL_CONFIG") or os.environ.get("KUBECONFIG"):
        raise ValueError("alternate configuration stores are not supported")
    return json.loads(CONFIG.read_text())


def save_config(config):
    fd, tmp_name = tempfile.mkstemp(prefix="config.", dir=str(ROOT), text=True)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(config, handle, sort_keys=True, indent=2)
            handle.write("\n")
        os.replace(tmp_name, CONFIG)
    finally:
        if os.path.exists(tmp_name):
            os.unlink(tmp_name)


def current(config):
    name = config.get("current")
    if name not in config.get("contexts", {}):
        raise ValueError("current context is not defined")
    return name, config["contexts"][name]


def endpoint_dir(ctx):
    path = ROOT / ctx["endpoint_dir"]
    path.mkdir(parents=True, exist_ok=True)
    return path


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


def main(argv):
    if any(token in {"--context", "--config"} or token.startswith("--context=") or token.startswith("--config=") for token in argv):
        return fail("scoped context and alternate config flags are not supported; use the shared selector")
    try:
        config = load_config()
        name, ctx = current(config)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        return fail(str(exc))
    if argv[:2] == ["config", "current-context"] and len(argv) == 2:
        print(json.dumps({"context": name, "endpoint_id": ctx["endpoint_id"]}, sort_keys=True))
        return 0
    if argv[:2] == ["config", "use-context"] and len(argv) == 3:
        requested = argv[2]
        if requested not in config["contexts"]:
            return fail(f"unknown context {requested}")
        prior = config["current"]
        config["current"] = requested
        save_config(config)
        audit = ROOT / "selector_audit.jsonl"
        with audit.open("a") as handle:
            handle.write(json.dumps({
                "at": time.time(),
                "pid": os.getpid(),
                "uid": os.getuid(),
                "from": prior,
                "to": requested,
            }, sort_keys=True) + "\n")
        print(json.dumps({"previous": prior, "current": requested, "endpoint_id": config["contexts"][requested]["endpoint_id"]}, sort_keys=True))
        return 0
    if argv[:1] == ["get"] and len(argv) in {2, 3} and argv[1] == "rollout":
        resource = argv[2] if len(argv) == 3 else "rollout-controller"
        health = endpoint_dir(ctx) / "health.json"
        if not health.is_file():
            return fail("endpoint health is unavailable")
        payload = json.loads(health.read_text())
        if not payload.get("healthy"):
            return fail("endpoint is unhealthy")
        print(json.dumps({"resource": resource, "context": name, "endpoint_id": ctx["endpoint_id"], "namespace": ctx["namespace"], "healthy": True}, sort_keys=True))
        return 0
    if argv[:1] == ["apply"]:
        if len(argv) != 3 or argv[1] != "-f":
            return fail("usage: clusterctl apply -f MANIFEST")
        manifest_path = Path(argv[2])
        if not manifest_path.is_file():
            return fail(f"manifest not found: {manifest_path}")
        manifest = json.loads(manifest_path.read_text())
        resource_name = manifest.get("metadata", {}).get("name")
        if not resource_name:
            return fail("manifest metadata.name is required")
        target = endpoint_dir(ctx) / "applied" / f"{resource_name}.json"
        write_json(target, {
            "resource": resource_name,
            "context": name,
            "endpoint_id": ctx["endpoint_id"],
            "namespace": ctx["namespace"],
            "manifest": manifest,
            "applied_by_uid": os.getuid(),
            "applied_at": time.time(),
            "status": "ready",
        })
        print(json.dumps({"applied": resource_name, "context": name, "endpoint_id": ctx["endpoint_id"], "status": "ready"}, sort_keys=True))
        return 0
    if argv[:2] == ["rollout", "status"] and len(argv) in {3, 4}:
        resource_name = argv[2]
        artifact = endpoint_dir(ctx) / "applied" / f"{resource_name}.json"
        if not artifact.is_file():
            return fail(f"rollout {resource_name} is not applied in current context {name}")
        payload = json.loads(artifact.read_text())
        if payload.get("context") != name or payload.get("status") != "ready":
            return fail("rollout artifact does not match current context")
        verified = endpoint_dir(ctx) / "verified" / f"{resource_name}.json"
        write_json(verified, {"resource": resource_name, "context": name, "endpoint_id": ctx["endpoint_id"], "status": "ready", "verified_by_uid": os.getuid(), "verified_at": time.time()})
        print(json.dumps({"resource": resource_name, "context": name, "endpoint_id": ctx["endpoint_id"], "status": "ready"}, sort_keys=True))
        return 0
    return fail("unsupported command")


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        raise SystemExit(f"clusterctl: {exc}")
