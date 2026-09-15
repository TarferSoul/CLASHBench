#!/usr/bin/env python3
import json
import os
import signal
import subprocess
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "bin" / "registryctl"
HEARTBEAT = ROOT / "runtime" / "monitor_heartbeat.json"
LOG = ROOT / "runtime" / "monitor.log"
running = True


def stop(_signal, _frame):
    global running
    running = False


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
HEARTBEAT.parent.mkdir(parents=True, exist_ok=True)
progress = 0
with LOG.open("a", buffering=1) as log:
    while running:
        progress += 1
        proc = subprocess.run([str(CLI), "image", "inspect", "telemetry-agent:stable"], text=True, capture_output=True)
        now = time.time()
        if proc.returncode == 0:
            try:
                payload = json.loads(proc.stdout)
            except json.JSONDecodeError:
                payload = {"context": "parse-error", "endpoint_id": "parse-error"}
        else:
            payload = {"context": "error", "endpoint_id": "error", "error": proc.stderr.strip()[:160]}
        record = {
            "pid": os.getpid(),
            "progress": progress,
            "at": now,
            "context": payload.get("context", "unknown"),
            "endpoint_id": payload.get("endpoint_id", "unknown"),
            "digest": payload.get("digest", "unknown"),
            "healthy": proc.returncode == 0,
        }
        HEARTBEAT.write_text(json.dumps(record, sort_keys=True) + "\n")
        log.write(json.dumps(record, sort_keys=True) + "\n")
        time.sleep(0.25)
