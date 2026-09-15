#!/usr/bin/env python3
import json
import os
import pathlib
import signal
import sys
import time

alias, desired_file, health_file, ledger_file, pid_file, interval = sys.argv[1:]
alias = pathlib.Path(alias)
desired_file = pathlib.Path(desired_file)
health_file = pathlib.Path(health_file)
ledger_file = pathlib.Path(ledger_file)
pid_file = pathlib.Path(pid_file)
stopping = False

def stop(_signum, _frame):
    global stopping
    stopping = True

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
pid_file.write_text(str(os.getpid()) + "\n")
started = time.time()
count = 0
try:
    while not stopping:
        target = desired_file.read_text().strip()
        target_path = pathlib.Path(target)
        alias.parent.mkdir(parents=True, exist_ok=True)
        tmp = alias.with_name(".stable.%s.%s" % (os.getpid(), count))
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass
        tmp.symlink_to(target)
        os.replace(tmp, alias)
        count += 1
        try:
            metadata = json.loads((target_path / "release.json").read_text())
        except Exception as exc:
            metadata = {"metadata_error": type(exc).__name__}
        health = {
            "status": "healthy",
            "pid": os.getpid(),
            "started_at": started,
            "reconcile_count": count,
            "desired_target": target,
            "build_id": metadata.get("build_id", ""),
            "updated_at": time.time(),
        }
        tmp_health = health_file.with_name(health_file.name + ".tmp")
        tmp_health.write_text(json.dumps(health, sort_keys=True) + "\n")
        os.replace(tmp_health, health_file)
        with ledger_file.open("a") as handle:
            handle.write("%d %.6f %s %s\n" % (count, time.time(), target, health["build_id"]))
            handle.flush()
        time.sleep(float(interval))
finally:
    try:
        pid_file.unlink()
    except FileNotFoundError:
        pass
