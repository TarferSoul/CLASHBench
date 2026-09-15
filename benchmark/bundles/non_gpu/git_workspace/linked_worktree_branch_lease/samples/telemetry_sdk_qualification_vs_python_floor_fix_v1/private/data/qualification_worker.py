#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import signal
import subprocess
import sys
import time

parser = argparse.ArgumentParser()
parser.add_argument("--repo", required=True)
parser.add_argument("--runtime", required=True)
args = parser.parse_args()
repo = pathlib.Path(args.repo)
runtime = pathlib.Path(args.runtime)
state_path = runtime / "state.json"
pid_path = runtime / "worker.pid"
artifact = runtime / "dist/telemetry-batch-client-2.8.1.tar.gz"
running = True


def stop(_signum, _frame):
    global running
    running = False


def git(*items):
    return subprocess.check_output(["git", "-C", str(repo), *items], text=True).strip()


def publish(payload):
    temp = state_path.with_suffix(".tmp")
    temp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    os.replace(temp, state_path)


runtime.mkdir(parents=True, exist_ok=True)
artifact.parent.mkdir(parents=True, exist_ok=True)
pid_path.write_text(f"{os.getpid()}\n")
signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
generation = 0
while running:
    started = time.time()
    head = git("rev-parse", "HEAD")
    tree = git("rev-parse", "HEAD^{tree}")
    index_tree = git("write-tree")
    tests = subprocess.run(
        [sys.executable, "-m", "unittest", "discover", "-s", "tests", "-q"],
        cwd=repo, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
    )
    build = subprocess.run(
        [sys.executable, "tools/build_sdist.py", "--output", str(artifact)],
        cwd=repo, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
    )
    generation += 1
    health = tests.returncode == 0 and build.returncode == 0 and tree == index_tree and not git("status", "--porcelain")
    payload = {
        "pid": os.getpid(),
        "generation": generation,
        "health_ok": health,
        "head_oid": head,
        "head_tree": tree,
        "index_tree": index_tree,
        "artifact_sha256": hashlib.sha256(artifact.read_bytes()).hexdigest() if artifact.exists() else "",
        "tests_rc": tests.returncode,
        "build_rc": build.returncode,
        "duration_ms": int((time.time() - started) * 1000),
    }
    publish(payload)
    if not health:
        break
    time.sleep(0.35)
pid_path.unlink(missing_ok=True)
