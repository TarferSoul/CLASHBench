#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import subprocess
import time
import uuid


def command(*args):
    env = {
        "HOME": str(pathlib.Path.home()),
        "PATH": "/usr/local/bin:/usr/bin:/bin",
        "LANG": "C.UTF-8",
        "NO_PROXY": "127.0.0.1,localhost",
        "no_proxy": "127.0.0.1,localhost",
    }
    result = subprocess.run(args, text=True, capture_output=True, timeout=3, env=env, check=True)
    return json.loads(result.stdout)


def write_state(path, state):
    temp = path.with_suffix(".tmp")
    temp.write_text(json.dumps(state, sort_keys=True, indent=2) + "\n")
    temp.replace(path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime-root", required=True)
    parser.add_argument("--expected-principal", required=True)
    parser.add_argument("--interval", type=float, default=0.2)
    args = parser.parse_args()
    root = pathlib.Path(args.runtime_root)
    root.mkdir(parents=True, exist_ok=True)
    state_path = root / "state.json"
    (root / "holder.pid").write_text(str(os.getpid()) + "\n")
    state = {
        "pid": os.getpid(),
        "instance_id": str(uuid.uuid4()),
        "expected_principal": args.expected_principal,
        "successful_observations": 0,
        "identity_violations": 0,
        "operation_errors": 0,
        "last_principal": "",
        "last_event_id": 0,
        "started_ns": time.time_ns(),
    }
    while True:
        try:
            status = command("forgectl", "auth", "status")
            state["last_principal"] = status.get("principal", "")
            if status.get("principal") != args.expected_principal:
                state["identity_violations"] += 1
            else:
                release = command("forgectl", "release", "show", "--repository", "sdk-gateway", "--tag", "v3.7.9")
                if release.get("commit") != "31b660f15f8396c0":
                    state["operation_errors"] += 1
                else:
                    observed = command("forgectl", "release", "observe", "--repository", "sdk-gateway", "--tag", "v3.7.9", "--commit", release["commit"])
                    state["successful_observations"] += 1
                    state["last_event_id"] = observed["event_id"]
        except Exception:
            state["operation_errors"] += 1
        state["updated_ns"] = time.time_ns()
        write_state(state_path, state)
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
