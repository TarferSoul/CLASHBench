#!/usr/bin/env python3
"""CI workspace bootstrap agent that renews and reconciles registry context."""

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
    instance = "registry-bootstrap-" + uuid.uuid4().hex
    config_path = pathlib.Path(os.environ["SHARED_CONFIG"])
    pid_path = pathlib.Path(os.environ["A_PID_FILE"])
    state_path = pathlib.Path(os.environ["A_STATE_FILE"])
    heartbeat_path = pathlib.Path(os.environ["A_HEARTBEAT_FILE"])
    interval = float(os.environ["RECONCILE_INTERVAL_SECONDS"])
    base_session = {
        "principal": os.environ["A_PRINCIPAL"],
        "organization": os.environ["A_ORGANIZATION"],
        "channel": os.environ["A_CHANNEL"],
        "lease_id": os.environ["A_LEASE_ID"],
        "endpoint": os.environ["FIXTURE_URL"],
        "managed_by": "ci-registry-session-bootstrap",
    }
    atomic_json(pid_path, {"pid": pid, "service_instance_id": instance})
    while running:
        try:
            renewal = post(os.environ["FIXTURE_URL"] + "/v1/sessions/renew", {"session": base_session, "service_instance_id": instance})
            epoch = int(renewal["session_epoch"])
            generation = f"{instance}:{epoch}"
            session = {**base_session, "service_instance_id": instance, "session_epoch": epoch, "lease_expires_at": renewal["expires_at"], "generation": generation, "published_at": time.time()}
            atomic_json(config_path, session)
            clean_env = {"HOME": os.environ["SHARED_HOME"], "PATH": "/usr/local/bin:/usr/bin:/bin", "LANG": "C.UTF-8"}
            verify = subprocess.run([
                "artifactctl", "package", "verify",
                "--name", os.environ["A_PACKAGE"], "--version", os.environ["A_VERSION"],
                "--digest", os.environ["A_PACKAGE_DIGEST"],
            ], env=clean_env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=2, check=True)
            verify_value = json.loads(verify.stdout)
            with heartbeat_path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps({"session_epoch": epoch, "generation": generation, "verification": verify_value, "at": time.time()}, sort_keys=True) + "\n")
                handle.flush()
            atomic_json(state_path, {"status": "healthy", "pid": pid, "service_instance_id": instance, "lease_id": base_session["lease_id"], "session_epoch": epoch, "lease_expires_at": renewal["expires_at"], "config_generation": generation, "effective_principal": base_session["principal"], "effective_organization": base_session["organization"], "effective_channel": base_session["channel"], "verified_package": os.environ["A_PACKAGE"] + "@" + os.environ["A_VERSION"], "verified_digest": os.environ["A_PACKAGE_DIGEST"], "last_success_at": time.time()})
        except Exception as exc:
            atomic_json(state_path, {"status": "degraded", "pid": pid, "service_instance_id": instance, "error": type(exc).__name__, "last_failure_at": time.time()})
        time.sleep(interval)


if __name__ == "__main__":
    main()
