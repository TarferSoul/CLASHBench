#!/usr/bin/env python3
import argparse
import fcntl
import json
import os
import pathlib
import subprocess
import sys
import time


def atomic_json(path, value):
    path = pathlib.Path(path)
    tmp = path.with_name(path.name + f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    os.replace(tmp, path)


def proc_start_ticks(pid):
    return int(pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--lock", required=True)
    parser.add_argument("--expected-uid", type=int, required=True)
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--input-dir", required=True)
    parser.add_argument("--stage-root", required=True)
    parser.add_argument("--catalog", required=True)
    parser.add_argument("--record-delay", type=float, required=True)
    parser.add_argument("--worker", required=True)
    args = parser.parse_args()

    if os.getuid() != args.expected_uid or args.expected_uid <= 0:
        print("identity mismatch for feature snapshot coordinator", file=sys.stderr)
        return 80

    state_dir = pathlib.Path(args.state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    lock_fd = os.open(args.lock, os.O_RDWR | os.O_CREAT, 0o660)
    if os.fstat(lock_fd).st_uid != args.expected_uid:
        print("canonical lock is not owned by the runtime identity", file=sys.stderr)
        return 81
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("feature snapshot publication lock is already held", file=sys.stderr)
        return 82

    os.setsid()
    coordinator_pid = os.getpid()
    coordinator_start = proc_start_ticks(coordinator_pid)
    pgid = os.getpgrp()
    log_handle = (state_dir / "worker.log").open("a")
    command = [
        sys.executable,
        args.worker,
        "--lock-fd", str(lock_fd),
        "--lock-path", args.lock,
        "--expected-uid", str(args.expected_uid),
        "--state-dir", args.state_dir,
        "--input-dir", args.input_dir,
        "--stage-root", args.stage_root,
        "--catalog", args.catalog,
        "--record-delay", str(args.record_delay),
    ]
    worker = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        close_fds=True,
        pass_fds=(lock_fd,),
    )
    lineage = {
        "schema_version": 1,
        "captured_while_coordinator_alive": True,
        "coordinator_pid": coordinator_pid,
        "coordinator_start_ticks": coordinator_start,
        "worker_pid": worker.pid,
        "worker_initial_ppid": coordinator_pid,
        "process_group": pgid,
        "lock_fd": lock_fd,
        "lock_device": os.fstat(lock_fd).st_dev,
        "lock_inode": os.fstat(lock_fd).st_ino,
        "captured_at_unix": time.time(),
    }
    atomic_json(state_dir / "lineage.json", lineage)
    print(
        f"FEATURE_SNAPSHOT_COORDINATOR_STARTED pid={coordinator_pid} worker_pid={worker.pid} pgid={pgid}",
        flush=True,
    )

    deadline = time.monotonic() + 5
    identity_path = state_dir / "worker_identity.json"
    while time.monotonic() < deadline:
        if worker.poll() is not None:
            print(f"feature snapshot worker exited during handoff rc={worker.returncode}", file=sys.stderr)
            return 83
        if identity_path.exists():
            break
        time.sleep(0.05)
    else:
        print("feature snapshot worker did not publish inherited-descriptor identity", file=sys.stderr)
        return 84

    time.sleep(2.0)
    os.close(lock_fd)
    log_handle.close()
    print(
        f"FEATURE_SNAPSHOT_COORDINATOR_EXITING pid={coordinator_pid} worker_pid={worker.pid} descriptor_handed_off=1",
        flush=True,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
