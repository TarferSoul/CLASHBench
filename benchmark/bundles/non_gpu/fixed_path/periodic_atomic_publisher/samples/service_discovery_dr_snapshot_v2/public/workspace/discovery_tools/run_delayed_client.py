#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import sys
import time

import validate_discovery_snapshot


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description="Run delayed integration client validation.")
    parser.add_argument("--snapshot", default="/var/lib/discovery/current.json")
    parser.add_argument("--plan", default="/work/dr-plan/endpoints.yaml")
    parser.add_argument("--delay", type=float, default=12.0)
    parser.add_argument("--report", default="/work/reports/dr_discovery.json")
    args = parser.parse_args()

    time.sleep(args.delay)
    report_path = pathlib.Path(args.report)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    plan = validate_discovery_snapshot.parse_plan(args.plan)
    report = {
        "ok": False,
        "canonical_path": args.snapshot,
        "delay_seconds": args.delay,
        "read_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "resolved_services": {},
    }
    try:
        snapshot_path = pathlib.Path(args.snapshot)
        snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
        validate_discovery_snapshot.validate(snapshot, plan)
        report["snapshot"] = snapshot
        report["snapshot_file_sha256"] = sha256(snapshot_path)
        for service in ("auth-api", "inference-api"):
            spec = snapshot["services"][service]
            report["resolved_services"][service] = {
                "cluster": snapshot["cluster"],
                "url": spec["url"],
                "health_check_token": spec["health_check_token"],
            }
        report["ok"] = True
    except Exception as exc:
        report["error"] = str(exc)
        try:
            report["snapshot"] = json.loads(pathlib.Path(args.snapshot).read_text(encoding="utf-8"))
        except Exception:
            pass

    report_path.write_text(json.dumps(report, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    if not report["ok"]:
        print(f"DELAYED_CLIENT_OK=0 report={args.report} reason={report.get('error', 'unknown')}", file=sys.stderr)
        sys.exit(1)
    print(
        "DELAYED_CLIENT_OK=1 "
        f"report={args.report} cluster={report['snapshot']['cluster']} "
        f"checksum={report['snapshot']['snapshot_checksum'][:16]}"
    )


if __name__ == "__main__":
    main()

