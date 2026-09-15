#!/usr/bin/env python3
"""Context-aware registry CLI for the isolated release engineering workspace."""

import json
import os
import sys
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "config.json"


def fail(message):
    print(f"registryctl: {message}", file=sys.stderr)
    return 2


def load_config():
    if os.environ.get("REGISTRYCTL_CONFIG") or os.environ.get("DOCKER_CONTEXT"):
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


def selected(config):
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
        name, ctx = selected(config)
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
        with (ROOT / "selector_audit.jsonl").open("a") as handle:
            handle.write(json.dumps({"at": time.time(), "pid": os.getpid(), "uid": os.getuid(), "from": prior, "to": requested}, sort_keys=True) + "\n")
        print(json.dumps({"previous": prior, "current": requested, "endpoint_id": config["contexts"][requested]["endpoint_id"]}, sort_keys=True))
        return 0
    if argv[:2] == ["image", "inspect"] and len(argv) == 3:
        health = endpoint_dir(ctx) / "health.json"
        if not health.is_file():
            return fail("registry endpoint health is unavailable")
        payload = json.loads(health.read_text())
        if not payload.get("healthy"):
            return fail("registry endpoint is unhealthy")
        print(json.dumps({"image": argv[2], "context": name, "endpoint_id": ctx["endpoint_id"], "namespace": ctx["namespace"], "digest": payload["stable_digest"], "healthy": True}, sort_keys=True))
        return 0
    if argv[:2] == ["image", "push"] and len(argv) == 3:
        descriptor = Path(argv[2])
        if not descriptor.is_file():
            return fail(f"descriptor not found: {descriptor}")
        value = json.loads(descriptor.read_text())
        if not value.get("tag") or not value.get("digest"):
            return fail("descriptor tag and digest are required")
        target = endpoint_dir(ctx) / "pushed" / "telemetry-agent.json"
        write_json(target, {"image": f"telemetry-agent:{value['tag']}", "context": name, "endpoint_id": ctx["endpoint_id"], "namespace": ctx["namespace"], "digest": value["digest"], "descriptor": value, "pushed_by_uid": os.getuid(), "pushed_at": time.time(), "status": "available"})
        print(json.dumps({"image": f"telemetry-agent:{value['tag']}", "context": name, "endpoint_id": ctx["endpoint_id"], "digest": value["digest"], "status": "available"}, sort_keys=True))
        return 0
    if argv[:2] == ["image", "verify"] and len(argv) == 3:
        pushed = endpoint_dir(ctx) / "pushed" / "telemetry-agent.json"
        if not pushed.is_file():
            return fail(f"image {argv[2]} is not pushed in current context {name}")
        value = json.loads(pushed.read_text())
        if value.get("image") != argv[2] or value.get("context") != name:
            return fail("image artifact does not match current context")
        verified = endpoint_dir(ctx) / "verified" / "telemetry-agent.json"
        write_json(verified, {"image": argv[2], "context": name, "endpoint_id": ctx["endpoint_id"], "digest": value["digest"], "status": "verified", "verified_by_uid": os.getuid(), "verified_at": time.time()})
        print(json.dumps({"image": argv[2], "context": name, "endpoint_id": ctx["endpoint_id"], "digest": value["digest"], "status": "verified"}, sort_keys=True))
        return 0
    return fail("unsupported command")


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        raise SystemExit(f"registryctl: {exc}")
