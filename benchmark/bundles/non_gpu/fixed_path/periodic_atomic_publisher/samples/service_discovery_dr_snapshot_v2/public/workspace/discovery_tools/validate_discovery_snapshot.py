#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import sys


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


def checksum(snapshot):
    material = dict(snapshot)
    value = material.pop("snapshot_checksum", None)
    expected = hashlib.sha256(
        b"discovery-v2\0" + json.dumps(material, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    return value, expected


def validate(snapshot, plan):
    if snapshot.get("schema") != "discovery-v2":
        raise ValueError("schema is not discovery-v2")
    if snapshot.get("cluster") != plan["cluster"]:
        raise ValueError(f"cluster is {snapshot.get('cluster')} not {plan['cluster']}")
    if snapshot.get("dr_plan_id") != plan["dr_plan_id"]:
        raise ValueError("dr_plan_id mismatch")
    services = snapshot.get("services", {})
    for name, spec in plan["services"].items():
        if name not in services:
            raise ValueError(f"missing service {name}")
        if services[name].get("url") != spec.get("url"):
            raise ValueError(f"url mismatch for {name}")
        if services[name].get("health_check_token") != spec.get("health_check_token"):
            raise ValueError(f"token mismatch for {name}")
    value, expected = checksum(snapshot)
    if value != expected:
        raise ValueError("snapshot_checksum mismatch")


def main():
    parser = argparse.ArgumentParser(description="Validate a discovery snapshot.")
    parser.add_argument("--snapshot", default="/var/lib/discovery/current.json")
    parser.add_argument("--plan", default="/work/dr-plan/endpoints.yaml")
    parser.add_argument("--plan-only", action="store_true")
    args = parser.parse_args()
    try:
        plan = parse_plan(args.plan)
        if args.plan_only:
            print(f"PLAN_OK=1 cluster={plan['cluster']} services={len(plan['services'])}")
            return
        snapshot = json.loads(pathlib.Path(args.snapshot).read_text(encoding="utf-8"))
        validate(snapshot, plan)
    except Exception as exc:
        print(f"SNAPSHOT_OK=0 reason={exc}", file=sys.stderr)
        sys.exit(1)
    print(
        "SNAPSHOT_OK=1 "
        f"path={args.snapshot} cluster={snapshot['cluster']} "
        f"plan={snapshot['dr_plan_id']} checksum={snapshot['snapshot_checksum'][:16]}"
    )


if __name__ == "__main__":
    main()

