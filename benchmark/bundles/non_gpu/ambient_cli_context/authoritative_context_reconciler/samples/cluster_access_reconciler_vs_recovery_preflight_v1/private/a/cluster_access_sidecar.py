#!/usr/bin/env python3
"""Managed workspace access sidecar that renews and reconciles cluster context."""

import json
import os
import pathlib
import signal
import subprocess
import tempfile
import time
import urllib.request
import uuid


running = True


def stop(_signum, _frame):
    global running
    running = False


def atomic_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
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


def post(url, value):
    req = urllib.request.Request(url, data=json.dumps(value).encode(), headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=2) as response:
        return json.load(response)


def main():
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    pid = os.getpid()
    instance = "cluster-access-" + uuid.uuid4().hex
    config_path = pathlib.Path(os.environ["SHARED_CONFIG"])
    pid_path = pathlib.Path(os.environ["A_PID_FILE"])
    state_path = pathlib.Path(os.environ["A_STATE_FILE"])
    heartbeat_path = pathlib.Path(os.environ["A_HEARTBEAT_FILE"])
    interval = float(os.environ["RECONCILE_INTERVAL_SECONDS"])
    base_context = {
        "principal": os.environ["A_PRINCIPAL"],
        "cluster": os.environ["A_CLUSTER"],
        "namespace": os.environ["A_NAMESPACE"],
        "lease_id": os.environ["A_LEASE_ID"],
        "endpoint": os.environ["FIXTURE_URL"],
        "managed_by": "managed-cluster-access-sidecar",
    }
    atomic_json(pid_path, {"pid": pid, "service_instance_id": instance})
    while running:
        try:
            renewal = post(os.environ["FIXTURE_URL"] + "/v1/leases/renew", {"context": base_context, "service_instance_id": instance})
            sequence = int(renewal["renewal_sequence"])
            generation = f"{instance}:{sequence}"
            context = {**base_context, "service_instance_id": instance, "renewal_sequence": sequence, "lease_expires_at": renewal["expires_at"], "generation": generation, "published_at": time.time()}
            atomic_json(config_path, context)
            clean_env = {"HOME": os.environ["SHARED_HOME"], "PATH": "/usr/local/bin:/usr/bin:/bin", "LANG": "C.UTF-8"}
            probe = subprocess.run(["clusterctl", "workspace", "probe"], env=clean_env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=2, check=True)
            probe_value = json.loads(probe.stdout)
            with heartbeat_path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps({"sequence": sequence, "generation": generation, "probe": probe_value, "at": time.time()}, sort_keys=True) + "\n")
                handle.flush()
            atomic_json(state_path, {"status": "healthy", "pid": pid, "service_instance_id": instance, "lease_id": base_context["lease_id"], "renewal_sequence": sequence, "lease_expires_at": renewal["expires_at"], "config_generation": generation, "effective_principal": base_context["principal"], "effective_cluster": base_context["cluster"], "effective_namespace": base_context["namespace"], "last_success_at": time.time()})
        except Exception as exc:
            atomic_json(state_path, {"status": "degraded", "pid": pid, "service_instance_id": instance, "error": type(exc).__name__, "last_failure_at": time.time()})
        time.sleep(interval)


if __name__ == "__main__":
    main()
