#!/usr/bin/python3
"""Run the fixed-width model-registry PostgreSQL release validation suite."""

import argparse
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import time

import psycopg2


def atomic_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, path)


def capacity_error(text):
    needles = [
        "remaining connection slots are reserved",
        "too many clients already",
        "sorry, too many clients already",
        "connection limit exceeded",
        "could not connect to server",
        "OperationalError",
    ]
    lowered = text.lower()
    return any(needle.lower() in lowered for needle in needles)


def schema_fingerprint(plan):
    conn = psycopg2.connect(
        host=plan["host"],
        port=plan["port"],
        dbname=plan["database"],
        user=plan["role"],
        application_name="release_validation:schema_fingerprint",
        connect_timeout=3,
    )
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT table_name, column_name, data_type, is_nullable
                FROM information_schema.columns
                WHERE table_schema = %s
                ORDER BY table_name, ordinal_position
                """,
                (plan["schema"],),
            )
            rows = [list(row) for row in cur.fetchall()]
    finally:
        conn.close()
    payload = json.dumps(rows, separators=(",", ":"), sort_keys=True)
    return hashlib.sha256(payload.encode()).hexdigest(), rows


def load_worker_jsons(root):
    items = []
    for path in sorted(pathlib.Path(root).glob("worker_*.json")):
        try:
            data = json.loads(path.read_text())
        except Exception as exc:
            data = {"path": str(path), "status": "unreadable", "error": str(exc)}
        data.setdefault("path", str(path))
        items.append(data)
    return items


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    suite_root = pathlib.Path(__file__).resolve().parent
    plan = json.loads(pathlib.Path(args.plan).read_text())
    workers = int(plan["pytest_workers"])
    if workers != 10:
        raise SystemExit("the release validation contract requires exactly ten pytest-xdist workers")

    output = pathlib.Path(args.output)
    if output.exists():
        shutil.rmtree(output)
    (output / plan["worker_result_dir"]).mkdir(parents=True)
    (output / plan["worker_error_dir"]).mkdir(parents=True)
    run_state = output / "run_state"
    run_state.mkdir()

    junit_path = output / plan["junit_xml"]
    manifest_path = output / plan["output_manifest"]
    attempt_path = output / "pytest_attempt.json"

    env = os.environ.copy()
    env.update(
        {
            "MODEL_REGISTRY_VALIDATION_PLAN": str(pathlib.Path(args.plan)),
            "MODEL_REGISTRY_OUTPUT_DIR": str(output),
            "MODEL_REGISTRY_RUN_STATE": str(run_state),
            "PYTHONPATH": str(suite_root) + os.pathsep + env.get("PYTHONPATH", ""),
        }
    )
    command = [
        sys.executable,
        "-m",
        "pytest",
        "-n",
        str(workers),
        "--dist",
        "load",
        "--tb=short",
        "--disable-warnings",
        "--junitxml",
        str(junit_path),
        str(suite_root / "tests"),
    ]
    started_ns = time.time_ns()
    try:
        proc = subprocess.run(
            command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            timeout=int(plan["pytest_timeout_seconds"]),
        )
    except subprocess.TimeoutExpired as exc:
        proc = subprocess.CompletedProcess(
            command,
            124,
            stdout=exc.stdout or "",
            stderr=(exc.stderr or "") + "\npytest timeout expired",
        )
    finished_ns = time.time_ns()

    result_items = load_worker_jsons(output / plan["worker_result_dir"])
    error_items = load_worker_jsons(output / plan["worker_error_dir"])
    passed = sorted(int(item["shard"]) for item in result_items if item.get("status") == "passed")
    failed = sorted(
        set(int(item.get("shard", -1)) for item in result_items + error_items if item.get("status") != "passed")
        - {-1}
    )
    connected_markers = sorted(run_state.glob("connected_*.json"))
    marker_count = len(connected_markers)
    peak = marker_count
    for item in result_items + error_items:
        try:
            peak = max(peak, int(item.get("peak_concurrent_sessions", 0)))
        except Exception:
            pass

    checksum = ""
    schema_rows = []
    schema_error = ""
    try:
        checksum, schema_rows = schema_fingerprint(plan)
    except Exception as exc:
        schema_error = str(exc)

    stdout_tail = proc.stdout[-6000:] if proc.stdout else ""
    stderr_tail = proc.stderr[-6000:] if proc.stderr else ""
    cap_error = capacity_error(stdout_tail + "\n" + stderr_tail + "\n" + json.dumps(error_items))
    complete = (
        proc.returncode == 0
        and len(passed) == workers
        and not failed
        and len(result_items) == workers
        and peak >= int(plan["required_sessions"])
        and bool(checksum)
        and junit_path.is_file()
    )
    status = "complete" if complete else "incomplete"

    attempt = {
        "request_id": plan["request_id"],
        "pytest_command": command,
        "pytest_workers": workers,
        "required_sessions": int(plan["required_sessions"]),
        "pytest_rc": proc.returncode,
        "pytest_stdout": stdout_tail,
        "pytest_stderr": stderr_tail,
        "started_ns": started_ns,
        "finished_ns": finished_ns,
        "capacity_error": cap_error,
        "result_file_count": len(result_items),
        "error_file_count": len(error_items),
        "connected_marker_count": marker_count,
        "peak_concurrent_sessions": peak,
    }
    atomic_json(attempt_path, attempt)

    manifest = {
        "request_id": plan["request_id"],
        "status": status,
        "database": plan["database"],
        "schema": plan["schema"],
        "role": plan["role"],
        "host": plan["host"],
        "port": plan["port"],
        "model_name": plan["model_name"],
        "expected_latest_version_id": int(plan["expected_latest_version_id"]),
        "pytest_workers": workers,
        "required_sessions": int(plan["required_sessions"]),
        "passed_shards": passed,
        "failed_shards": failed,
        "peak_concurrent_sessions": peak,
        "schema_checksum": checksum,
        "schema_columns": schema_rows,
        "schema_error": schema_error,
        "junit_xml": str(junit_path),
        "worker_result_dir": str(output / plan["worker_result_dir"]),
        "worker_error_dir": str(output / plan["worker_error_dir"]),
        "result_file_count": len(result_items),
        "error_file_count": len(error_items),
        "pytest_rc": proc.returncode,
        "capacity_error": cap_error,
        "completed_at_epoch": time.time(),
    }
    atomic_json(manifest_path, manifest)
    if complete:
        print(
            f"RELEASE_DB_VALIDATION_COMPLETE request_id={plan['request_id']} "
            f"workers={workers} peak={peak} schema_checksum={checksum}"
        )
        return 0
    print(
        f"RELEASE_DB_VALIDATION_INCOMPLETE request_id={plan['request_id']} "
        f"workers={workers} passed={len(passed)} failed={len(failed)} peak={peak} "
        f"capacity_error={int(cap_error)}",
        file=sys.stderr,
    )
    return 12


if __name__ == "__main__":
    raise SystemExit(main())
