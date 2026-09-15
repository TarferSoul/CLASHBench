#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import time


def parse_scalar(value):
    value = value.strip()
    if value.isdigit():
        return int(value)
    return value


def parse_plan(path):
    lines = pathlib.Path(path).read_text(encoding="utf-8").splitlines()
    plan = {"services": {}}
    current = None
    in_services = False
    for raw in lines:
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        text = raw.strip()
        if indent == 0:
            key, value = text.split(":", 1)
            key = key.strip()
            value = value.strip()
            if key == "services":
                in_services = True
            else:
                plan[key] = parse_scalar(value)
        elif in_services and indent == 2 and text.endswith(":"):
            current = text[:-1]
            plan["services"][current] = {}
        elif in_services and indent == 4 and current:
            key, value = text.split(":", 1)
            plan["services"][current][key.strip()] = parse_scalar(value)
        else:
            raise ValueError(f"unsupported endpoints.yaml line: {raw!r}")
    for required in ("dr_plan_id", "cluster"):
        if required not in plan:
            raise ValueError(f"missing {required}")
    for service in ("auth-api", "inference-api"):
        if service not in plan["services"]:
            raise ValueError(f"missing required service {service}")
    return plan


def canonical_bytes(payload):
    return json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")


def snapshot_checksum(payload):
    material = dict(payload)
    material.pop("snapshot_checksum", None)
    return hashlib.sha256(b"discovery-v2\0" + canonical_bytes(material)).hexdigest()


def fsync_dir(path):
    fd = os.open(str(path), os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_write_json(output, payload):
    path = pathlib.Path(output)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.parent / f".{path.name}.drtmp.{os.getpid()}"
    encoded = json.dumps(payload, sort_keys=True, indent=2).encode("utf-8") + b"\n"
    with open(tmp, "wb") as handle:
        handle.write(encoded)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)
    fsync_dir(path.parent)
    return hashlib.sha256(encoded).hexdigest()


def build_snapshot(plan):
    services = {}
    for name, spec in sorted(plan["services"].items()):
        services[name] = {
            "url": str(spec["url"]),
            "health_check_token": str(spec["health_check_token"]),
            "weight": int(spec.get("weight", 100)),
        }
    payload = {
        "schema": "discovery-v2",
        "publisher": "dr-endpoint-builder",
        "cluster": plan["cluster"],
        "dr_plan_id": plan["dr_plan_id"],
        "endpoint_count": len(services),
        "services": services,
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    payload["snapshot_checksum"] = snapshot_checksum(payload)
    return payload


def main():
    parser = argparse.ArgumentParser(description="Build a DR endpoint snapshot.")
    parser.add_argument("--plan", default="/work/dr-plan/endpoints.yaml")
    parser.add_argument("--output", default="/var/lib/discovery/current.json")
    args = parser.parse_args()
    plan = parse_plan(args.plan)
    snapshot = build_snapshot(plan)
    digest = atomic_write_json(args.output, snapshot)
    print(
        "DR_SNAPSHOT_WRITTEN=1 "
        f"path={args.output} cluster={snapshot['cluster']} "
        f"plan={snapshot['dr_plan_id']} digest={digest[:16]}"
    )


if __name__ == "__main__":
    main()

