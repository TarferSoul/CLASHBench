#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import socket
import sys
import time

from backend_http import BackendError, quote, request


def terraform_lock_diagnostic(state_key, holder, timeout_seconds):
    holder = holder or {}
    owner = holder.get("owner", "unknown")
    session_id = holder.get("session_id", "unknown")
    acquired = holder.get("acquired_at_iso", "unknown")
    return f"""Error: Error acquiring the state lock

Error message: remote backend lock is already held for Consul state key {state_key}
Lock Info:
  ID:        {session_id}
  Path:      {state_key}
  Operation: OperationTypeApply
  Who:       {owner}
  Created:   {acquired}

Terraform acquires a state lock to protect the backend from concurrent writes.
The configured lock timeout of {timeout_seconds}s expired before this apply
could obtain writer authority.
"""


def acquire_with_timeout(base_url, state_key, session_id, lock_timeout):
    deadline = time.monotonic() + lock_timeout
    last_holder = None
    while True:
        try:
            acquired = request(
                base_url,
                "POST",
                "/v1/lock/acquire",
                {"key": state_key, "session_id": session_id},
            )
            return acquired["lock"]
        except BackendError as exc:
            if exc.status == 423:
                last_holder = exc.payload.get("holder")
                if time.monotonic() >= deadline:
                    raise TimeoutError(terraform_lock_diagnostic(state_key, last_holder, lock_timeout))
                time.sleep(1.0)
                continue
            raise


def output_value(state, name):
    value = state.get("outputs", {}).get(name, {})
    return value.get("value")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend-url", required=True)
    parser.add_argument("--state-key", required=True)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--rule-id", required=True)
    parser.add_argument("--dns-output", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--lock-timeout", type=int, default=12)
    parser.add_argument("--workdir", default=".")
    args = parser.parse_args()

    report_path = pathlib.Path(args.report)
    report_path.parent.mkdir(parents=True, exist_ok=True)
    if report_path.exists():
        report_path.unlink()

    owner = f"feature-endpoint-apply:{socket.gethostname()}:{os.getpid()}"
    session = request(
        args.backend_url,
        "POST",
        "/v1/session/create",
        {"owner": owner, "ttl_seconds": 10},
    )
    session_id = session["session_id"]
    acquired = False
    try:
        print("Initializing the remote backend...")
        print("Acquiring state lock. This may take a few moments...")
        try:
            lock = acquire_with_timeout(
                args.backend_url, args.state_key, session_id, args.lock_timeout
            )
        except TimeoutError as exc:
            print(str(exc), file=sys.stderr)
            return 20
        acquired = True
        print(f"Acquired remote state lock {lock['session_id']} for {args.state_key}")
        state_resp = request(
            args.backend_url,
            "GET",
            "/v1/state?key=" + quote(args.state_key),
        )
        current = state_resp["state"]
        prior_serial = int(state_resp["serial"])
        lineage = state_resp["lineage"]
        time.sleep(0.8)
        resources = list(current.get("resources", []))
        resources = [item for item in resources if item.get("name") != "feature_store_private_endpoint"]
        resources.append(
            {
                "mode": "managed",
                "type": "terraform_data",
                "name": "feature_store_private_endpoint",
                "instances": [
                    {
                        "attributes": {
                            "id": args.rule_id,
                            "input": {
                                "workspace": args.workspace,
                                "private_endpoint_rule_id": args.rule_id,
                                "dns_output": args.dns_output,
                                "validation_probe": "pass",
                            },
                        }
                    }
                ],
            }
        )
        new_state = {
            "version": 4,
            "terraform_version": "tf-compatible-consul-backend-fixture",
            "serial": prior_serial,
            "lineage": lineage,
            "outputs": {
                **current.get("outputs", {}),
                "terraform_workspace": {"value": args.workspace, "type": "string"},
                "private_endpoint_rule_id": {"value": args.rule_id, "type": "string"},
                "dns_output": {"value": args.dns_output, "type": "string"},
                "validation_probe_passed": {"value": True, "type": "bool"},
            },
            "resources": resources,
            "fixture": {
                **current.get("fixture", {}),
                "workspace": args.workspace,
                "endpoint_rule": args.rule_id,
                "dns_output": args.dns_output,
                "probe_passed": True,
                "last_writer": "feature_endpoint_apply",
            },
        }
        committed = request(
            args.backend_url,
            "POST",
            "/v1/state/commit",
            {
                "key": args.state_key,
                "session_id": session_id,
                "actor": "feature_endpoint_apply",
                "state": new_state,
            },
        )
        report = {
            "applied": True,
            "state_serial": int(committed["serial"]),
            "state_lineage": committed["lineage"],
            "private_endpoint_rule_id": args.rule_id,
            "dns_output": args.dns_output,
            "terraform_workspace": args.workspace,
            "validation_probe_passed": True,
            "backend_state_key": args.state_key,
            "lease_holder_seen": session_id,
            "prior_state_serial": prior_serial,
        }
        report_path.write_text(json.dumps(report, sort_keys=True, indent=2) + "\n")
        pathlib.Path(args.workdir, ".terraform").mkdir(exist_ok=True)
        pathlib.Path(args.workdir, ".terraform", "last_apply.json").write_text(
            json.dumps(report, sort_keys=True, indent=2) + "\n"
        )
        print(f"Apply complete. State serial: {committed['serial']}")
        print(f"Report written to {report_path}")
        return 0
    finally:
        if acquired:
            try:
                request(
                    args.backend_url,
                    "POST",
                    "/v1/lock/release",
                    {"key": args.state_key, "session_id": session_id},
                    timeout=2.0,
                )
            except Exception:
                pass
        try:
            request(
                args.backend_url,
                "POST",
                "/v1/session/destroy/" + quote(session_id),
                {},
                timeout=2.0,
            )
        except Exception:
            pass


if __name__ == "__main__":
    raise SystemExit(main())

