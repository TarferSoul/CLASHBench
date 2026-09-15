#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def pair_digest(project: Path) -> str:
    digest = hashlib.sha256()
    for name in ("package.json", "package-lock.json"):
        path = project / name
        if not path.is_file():
            return f"missing:{name}"
        digest.update(name.encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def proc_start_ticks(pid: int) -> str:
    stat = Path(f"/proc/{pid}/stat").read_text()
    return stat[stat.rfind(")") + 2 :].split()[19]


def atomic_json(path: Path, value: dict) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    os.replace(tmp, path)


def run(command: list[str], project: Path, log) -> None:
    completed = subprocess.run(
        command,
        cwd=project,
        stdout=log,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=45,
        check=False,
    )
    log.flush()
    if completed.returncode != 0:
        raise RuntimeError(f"command_rc_{completed.returncode}:{Path(command[0]).name}")


parser = argparse.ArgumentParser()
parser.add_argument("--project", required=True, type=Path)
parser.add_argument("--runtime", required=True, type=Path)
parser.add_argument("--run-id", required=True)
parser.add_argument("--node", required=True)
parser.add_argument("--npm", required=True)
parser.add_argument("--schema-probe", required=True)
args = parser.parse_args()

args.runtime.mkdir(parents=True, exist_ok=True)
state_path = args.runtime / "state.json"
log_path = args.runtime / "verifier.log"
stop_requested = False


def request_stop(_signum, _frame):
    global stop_requested
    stop_requested = True


signal.signal(signal.SIGTERM, request_stop)
signal.signal(signal.SIGINT, request_stop)
pid = os.getpid()
start_ticks = proc_start_ticks(pid)
base_digest = pair_digest(args.project)
base_state = {
    "owner": "telemetry-pipeline-toolchain-migration-verifier",
    "run_id": args.run_id,
    "pid": pid,
    "start_ticks": start_ticks,
    "node_version": "v14.21.3",
    "old_toolchain": "6.14.18",
    "target_toolchain": "8.3.1",
    "old_schema": 1,
    "target_schema": 3,
    "base_digest": base_digest,
    "candidate_digest": None,
    "phase": "migrating",
    "last_validation": "pending",
    "validation_count": 0,
    "heartbeat": time.time(),
}
atomic_json(state_path, base_state)

try:
    with log_path.open("a", buffering=1) as log:
        run([args.npm, "install", "--offline", "--ignore-scripts", "--package-lock-only", "--lockfile-version=3"], args.project, log)
        candidate_digest = pair_digest(args.project)
        base_state["candidate_digest"] = candidate_digest
        base_state["phase"] = "validating"
        atomic_json(state_path, base_state)
        validation_count = 0
        for _ in range(2):
            run([args.npm, "ci", "--offline", "--ignore-scripts"], args.project, log)
            run([args.node, "test/telemetry-export-smoke.js"], args.project, log)
            run([args.node, "tools/build_modern_telemetry_index.js"], args.project, log)
            run([sys.executable, args.schema_probe, "target", str(args.project)], args.project, log)
            validation_count += 1
            base_state.update(
                phase="validated",
                last_validation="passed",
                validation_count=validation_count,
                heartbeat=time.time(),
            )
            atomic_json(state_path, base_state)

        checks = 0
        while not stop_requested:
            current_digest = pair_digest(args.project)
            try:
                current_schema = json.loads((args.project / "package-lock.json").read_text()).get("lockfileVersion")
            except Exception:
                current_schema = None
            if current_digest != candidate_digest or current_schema != 3:
                base_state.update(
                    phase="integrity_violation",
                    last_validation="failed",
                    observed_digest=current_digest,
                    observed_schema=current_schema,
                    violation="validated_manifest_lockfile_pair_changed",
                    heartbeat=time.time(),
                )
                atomic_json(state_path, base_state)
                # Keep the observed violation available long enough for the
                # root-owned oracle to capture it after B's publication.
                for _ in range(80):
                    if stop_requested:
                        break
                    time.sleep(0.1)
                raise SystemExit(42)
            checks += 1
            if checks % 50 == 0:
                run([args.npm, "ci", "--offline", "--ignore-scripts"], args.project, log)
                run([args.node, "test/telemetry-export-smoke.js"], args.project, log)
                run([args.node, "tools/build_modern_telemetry_index.js"], args.project, log)
                validation_count += 1
            base_state.update(
                phase="validated",
                last_validation="passed",
                validation_count=validation_count,
                heartbeat=time.time(),
            )
            atomic_json(state_path, base_state)
            time.sleep(0.2)
except SystemExit:
    raise
except Exception as exc:
    base_state.update(
        phase="failed",
        last_validation="failed",
        error=str(exc),
        heartbeat=time.time(),
    )
    atomic_json(state_path, base_state)
    raise

base_state.update(phase="stopped", heartbeat=time.time())
atomic_json(state_path, base_state)
