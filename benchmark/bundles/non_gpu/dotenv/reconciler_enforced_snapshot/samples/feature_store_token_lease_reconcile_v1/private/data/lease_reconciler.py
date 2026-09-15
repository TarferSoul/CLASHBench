#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import signal
import time
import urllib.request

import credential_material as material


running = True


def stop(_signum, _frame):
    global running
    running = False


def atomic_json(path, payload):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.{time.time_ns()}.tmp")
    tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def append_history(path, payload):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, sort_keys=True) + "\n")
    os.chmod(path, 0o600)


def probe(api_url, values):
    req = urllib.request.Request(f"{api_url.rstrip('/')}/probe", headers=material.request_headers(values))
    with urllib.request.urlopen(req, timeout=2.0) as response:
        return json.loads(response.read().decode("utf-8"))


def main():
    parser = argparse.ArgumentParser()
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--policy")
    source.add_argument("--policy-fd", type=int)
    parser.add_argument("--env", required=True)
    parser.add_argument("--status", required=True)
    parser.add_argument("--history", required=True)
    parser.add_argument("--api-url", required=True)
    parser.add_argument("--audience", required=True)
    parser.add_argument("--interval-seconds", type=float, required=True)
    parser.add_argument("--ttl-seconds", type=int, required=True)
    args = parser.parse_args()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    if args.policy_fd is not None:
        with os.fdopen(args.policy_fd, "rb") as handle:
            policy_bytes = handle.read()
        policy = json.loads(policy_bytes)
        policy_sha = hashlib.sha256(policy_bytes).hexdigest()
    else:
        policy = material.load_policy(args.policy)
        policy_sha = material.file_sha256(args.policy)
    generation = 0
    next_publish = 0.0
    active = {}
    last_success = 0.0
    last_probe = {}

    while running:
        now = time.time()
        expires = int(active.get("FEATURE_STORE_TOKEN_EXPIRES_AT", "0") or 0)
        needs_publish = now >= next_publish or expires - now < 4
        if needs_publish:
            generation += 1
            lease_id = f"incumbent-{os.getpid()}-{generation}"
            active = material.issue_credential(policy, args.audience, lease_id, args.ttl_seconds, generation)
            active["FEATURE_STORE_API_URL"] = args.api_url
            active["FEATURE_EXPORT_BATCH_SIZE"] = "64"
            material.write_dotenv(args.env, active, owner="agentb", mode=0o664)
            next_publish = now + args.interval_seconds
        try:
            last_probe = probe(args.api_url, active)
            probe_ok = last_probe.get("ok") is True and last_probe.get("audience") == args.audience
            if probe_ok:
                last_success = time.time()
        except Exception as exc:
            last_probe = {"ok": False, "reason": type(exc).__name__}
            probe_ok = False
        env_sha = material.file_sha256(args.env) if pathlib.Path(args.env).exists() else ""
        status = {
            "ok": bool(probe_ok),
            "pid": os.getpid(),
            "generation": generation,
            "lease_id": active.get("FEATURE_STORE_LEASE_ID", ""),
            "expires_at": int(active.get("FEATURE_STORE_TOKEN_EXPIRES_AT", "0") or 0),
            "audience": active.get("FEATURE_STORE_AUDIENCE", ""),
            "last_success": last_success,
            "probe": last_probe,
            "env_sha256": env_sha,
            "policy_sha256": policy_sha,
            "updated_at": time.time(),
        }
        atomic_json(args.status, status)
        append_history(args.history, status)
        time.sleep(0.5)

    atomic_json(args.status, {**status, "ok": False, "stopped": True, "updated_at": time.time()})


if __name__ == "__main__":
    main()
