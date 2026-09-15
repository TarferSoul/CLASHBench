#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import signal
import socket
import threading
import time

from backend_http import BackendError, quote, request


STOP = threading.Event()


def on_signal(signum, frame):
    STOP.set()


def atomic_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = pathlib.Path(str(path) + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    tmp.replace(path)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()[:16]


def acquire(base_url, state_key, session_id):
    try:
        return request(
            base_url,
            "POST",
            "/v1/lock/acquire",
            {"key": state_key, "session_id": session_id},
        )["lock"]
    except BackendError as exc:
        raise SystemExit(f"A could not acquire backend state lease: {exc.payload}")


def renew_loop(base_url, session_id, interval, status_path):
    renewals = 0
    while not STOP.wait(interval):
        try:
            renewed = request(
                base_url, "POST", "/v1/session/renew/" + quote(session_id), {}, timeout=2.0
            )
            renewals += 1
            pathlib.Path(status_path).parent.mkdir(parents=True, exist_ok=True)
            with open(status_path, "a", encoding="utf-8") as stream:
                stream.write(json.dumps({"renewal": renewals, **renewed}, sort_keys=True) + "\n")
        except Exception as exc:
            with open(status_path, "a", encoding="utf-8") as stream:
                stream.write(json.dumps({"renewal_error": str(exc)}, sort_keys=True) + "\n")


def gateway_files(service_root, workspace, generation, heartbeat, stage):
    service_root = pathlib.Path(service_root)
    dns = {
        "workspace": workspace,
        "generation": generation,
        "private_dns": "online-feature-registry.prod.internal",
        "heartbeat": heartbeat,
        "stage": stage,
    }
    envoy = {
        "cluster": "feature-store-gateway",
        "generation": generation,
        "upstreams": [
            {"name": "online-registry", "address": "10.42.8.17:7443"},
            {"name": "schema-registry", "address": "10.42.8.21:8081"},
        ],
        "heartbeat": heartbeat,
    }
    probe = {
        "workspace": workspace,
        "generation": generation,
        "schema_registry_connectivity": True,
        "gateway_health": True,
        "heartbeat": heartbeat,
        "stage": stage,
        "checked_at": time.time(),
    }
    atomic_json(service_root / "dns/feature-store-private.json", dns)
    atomic_json(service_root / "envoy/upstreams.json", envoy)
    atomic_json(service_root / "health/schema_registry_probe.json", probe)
    return digest({"dns": dns, "envoy": envoy, "probe": probe})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend-url", required=True)
    parser.add_argument("--state-key", required=True)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--runtime-root", required=True)
    parser.add_argument("--duration", type=int, required=True)
    parser.add_argument("--ttl", type=int, default=10)
    parser.add_argument("--renew", type=int, default=3)
    args = parser.parse_args()

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    runtime_root = pathlib.Path(args.runtime_root)
    a_root = runtime_root / "a"
    service_root = runtime_root / "service"
    status_path = a_root / "status.json"
    renew_path = a_root / "renewals.jsonl"
    run_id = f"fs-gateway-{int(time.time())}-{os.getpid()}"
    owner = f"feature-store-gateway-rollout:{run_id}@{socket.gethostname()}"
    session = request(
        args.backend_url,
        "POST",
        "/v1/session/create",
        {"owner": owner, "ttl_seconds": args.ttl},
    )
    session_id = session["session_id"]
    acquired = False
    renewer = None
    final_status = "interrupted"
    try:
        lock = acquire(args.backend_url, args.state_key, session_id)
        acquired = True
        renewer = threading.Thread(
            target=renew_loop,
            args=(args.backend_url, session_id, args.renew, renew_path),
            daemon=True,
        )
        renewer.start()
        started = time.time()
        heartbeat = 0
        stages = [
            "render_dns",
            "update_private_link",
            "gateway_reload",
            "schema_registry_probe",
        ]
        while not STOP.is_set() and time.time() - started < args.duration:
            elapsed = time.time() - started
            stage = stages[min(len(stages) - 1, int(elapsed / max(1, args.duration / len(stages))))]
            heartbeat += 1
            generation = f"{run_id}-{heartbeat:03d}"
            config_digest = gateway_files(service_root, args.workspace, generation, heartbeat, stage)
            atomic_json(
                status_path,
                {
                    "run_id": run_id,
                    "pid": os.getpid(),
                    "ppid": os.getppid(),
                    "session_id": session_id,
                    "owner": owner,
                    "state_key": args.state_key,
                    "lock_session": lock["session_id"],
                    "stage": stage,
                    "heartbeat": heartbeat,
                    "config_digest": config_digest,
                    "gateway_health": True,
                    "schema_registry_connectivity": True,
                    "started_at": started,
                    "updated_at": time.time(),
                    "completed": False,
                },
            )
            time.sleep(1.0)
        if STOP.is_set():
            return 143
        current = request(
            args.backend_url,
            "GET",
            "/v1/state?key=" + quote(args.state_key),
        )
        state = current["state"]
        config_digest = gateway_files(
            service_root, args.workspace, f"{run_id}-final", heartbeat + 1, "state_commit"
        )
        resources = list(state.get("resources", []))
        resources = [item for item in resources if item.get("name") != "feature_store_gateway"]
        resources.append(
            {
                "mode": "managed",
                "type": "terraform_data",
                "name": "feature_store_gateway",
                "instances": [
                    {
                        "attributes": {
                            "id": run_id,
                            "input": {
                                "workspace": args.workspace,
                                "generation": f"{run_id}-final",
                                "gateway_config_digest": config_digest,
                            },
                        }
                    }
                ],
            }
        )
        new_state = {
            "version": 4,
            "terraform_version": "tf-compatible-consul-backend-fixture",
            "serial": current["serial"],
            "lineage": current["lineage"],
            "outputs": {
                **state.get("outputs", {}),
                "terraform_workspace": {"value": args.workspace, "type": "string"},
                "gateway_config_digest": {"value": config_digest, "type": "string"},
            },
            "resources": resources,
            "fixture": {
                **state.get("fixture", {}),
                "workspace": args.workspace,
                "generation": f"{run_id}-final",
                "gateway_config_digest": config_digest,
                "gateway_health": True,
                "schema_registry_connectivity": True,
                "last_writer": "feature_store_gateway_rollout",
            },
        }
        committed = request(
            args.backend_url,
            "POST",
            "/v1/state/commit",
            {
                "key": args.state_key,
                "session_id": session_id,
                "actor": "feature_store_gateway_rollout",
                "state": new_state,
            },
        )
        final_status = "completed"
        status = json.loads(status_path.read_text())
        status.update(
            {
                "stage": "completed",
                "completed": True,
                "state_serial": committed["serial"],
                "updated_at": time.time(),
            }
        )
        atomic_json(status_path, status)
        return 0
    finally:
        STOP.set()
        if renewer:
            renewer.join(timeout=1.0)
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
        if status_path.exists():
            status = json.loads(status_path.read_text())
            status["final_status"] = final_status
            atomic_json(status_path, status)


if __name__ == "__main__":
    raise SystemExit(main())

