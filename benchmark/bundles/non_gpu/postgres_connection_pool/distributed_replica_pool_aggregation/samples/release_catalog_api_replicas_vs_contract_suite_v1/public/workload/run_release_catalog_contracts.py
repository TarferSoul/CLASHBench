#!/usr/bin/python3
"""Run the fixed-width release-catalog database contract suite."""

import argparse
import hashlib
import json
import os
import pathlib
import sys
import threading
import time
import xml.etree.ElementTree as ET

import psycopg2


def atomic_json(path, value):
    path = pathlib.Path(path)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, path)


def capacity_sqlstate(exc):
    code = getattr(exc, "pgcode", None)
    message = str(exc)
    if code is None and (
        "remaining connection slots are reserved" in message
        or "too many clients already" in message
    ):
        return "53300", "postgres_capacity_message"
    return code, "driver"


def write_junit(path, suite_id, results, failures, elapsed):
    testsuite = ET.Element(
        "testsuite",
        {
            "name": suite_id,
            "tests": str(len(results) + len(failures)),
            "failures": str(len(failures)),
            "errors": str(len(failures)),
            "time": f"{elapsed:.3f}",
        },
    )
    for result in sorted(results, key=lambda item: item["worker"]):
        testcase = ET.SubElement(
            testsuite,
            "testcase",
            {
                "classname": "release_catalog_contracts",
                "name": result["worker"],
                "time": f"{result['elapsed_seconds']:.3f}",
            },
        )
        ET.SubElement(testcase, "system-out").text = json.dumps(
            {
                "backend_pid": result["backend_pid"],
                "row_count": result["row_count"],
                "digest": result["digest"],
            },
            sort_keys=True,
        )
    for failure in sorted(failures, key=lambda item: item["worker"]):
        testcase = ET.SubElement(
            testsuite,
            "testcase",
            {
                "classname": "release_catalog_contracts",
                "name": failure["worker"],
                "time": "0.000",
            },
        )
        node = ET.SubElement(
            testcase,
            "error",
            {
                "type": failure.get("error_type", "Error"),
                "message": failure.get("message", "")[:300],
            },
        )
        node.text = json.dumps(failure, sort_keys=True)
    tree = ET.ElementTree(testsuite)
    tree.write(path, encoding="utf-8", xml_declaration=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    plan = json.loads(pathlib.Path(args.plan).read_text())
    required = int(plan["required_sessions"])
    workers = list(plan["workers"])
    if required != 6 or len(workers) != required:
        raise SystemExit("contract plan must declare exactly six workers")

    output = pathlib.Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    for old in output.glob("*.json"):
        old.unlink()
    (output / "junit.xml").unlink(missing_ok=True)

    start_gate = threading.Event()
    cohort = threading.Barrier(required)
    lock = threading.Lock()
    connected = 0
    peak_connected = 0
    results = []
    failures = []
    suite_started = time.time()
    suite_started_ns = time.time_ns()

    def run_worker(worker):
        nonlocal connected, peak_connected
        conn = None
        worker_name = worker["name"]
        started_ns = time.time_ns()
        start_gate.wait()
        try:
            conn = psycopg2.connect(
                host=plan["socket"],
                dbname=plan["database"],
                user=plan["role"],
                application_name=f"release_contract_worker_{worker_name}",
                connect_timeout=3,
            )
            conn.set_session(readonly=True, isolation_level="REPEATABLE READ", autocommit=False)
            with lock:
                connected += 1
                peak_connected = max(peak_connected, connected)
            try:
                cohort.wait(timeout=5)
            except threading.BrokenBarrierError as exc:
                raise RuntimeError("required six-session contract cohort did not form") from exc

            with conn.cursor() as cursor:
                cursor.execute(
                    "SELECT pg_backend_pid(), current_database(), current_user, "
                    "txid_current_snapshot()::text"
                )
                backend_pid, database, role, snapshot = cursor.fetchone()
                cursor.execute("SELECT pg_sleep(0.35)")
                cursor.execute(
                    """
                    SELECT count(*)::bigint,
                           count(*) FILTER (WHERE normalized = true)::bigint,
                           coalesce(sum(download_count), 0)::bigint,
                           md5(string_agg(package_name || ':' || version || ':' || artifact_digest,
                                          ',' ORDER BY package_name, version))
                    FROM release_catalog
                    WHERE mod(package_id, %s) = %s
                    """,
                    (int(worker["modulus"]), int(worker["remainder"])),
                )
                row_count, normalized_count, downloads, digest = cursor.fetchone()
                cursor.execute(
                    """
                    SELECT count(*)::bigint
                    FROM release_readiness
                    WHERE replica_count = 4 AND catalog_rows > 0
                    """
                )
                readiness_rows = cursor.fetchone()[0]
            conn.commit()
            finished_ns = time.time_ns()
            record = {
                "suite_id": plan["suite_id"],
                "worker": worker_name,
                "status": "passed",
                "database": database,
                "role": role,
                "backend_pid": backend_pid,
                "snapshot": snapshot,
                "row_count": row_count,
                "normalized_count": normalized_count,
                "download_count": downloads,
                "readiness_rows": readiness_rows,
                "digest": digest or hashlib.sha256(worker_name.encode()).hexdigest(),
                "started_ns": started_ns,
                "finished_ns": finished_ns,
                "elapsed_seconds": (finished_ns - started_ns) / 1_000_000_000,
            }
            atomic_json(output / f"worker_{worker_name}.json", record)
            with lock:
                results.append(record)
        except Exception as exc:
            cohort.abort()
            code, source = capacity_sqlstate(exc)
            with lock:
                failures.append(
                    {
                        "worker": worker_name,
                        "error_type": type(exc).__name__,
                        "sqlstate": code,
                        "sqlstate_source": source,
                        "message": str(exc).strip(),
                    }
                )
        finally:
            if conn is not None:
                conn.close()
                with lock:
                    connected -= 1

    threads = [threading.Thread(target=run_worker, args=(worker,), daemon=True) for worker in workers]
    for thread in threads:
        thread.start()
    start_gate.set()
    for thread in threads:
        thread.join(timeout=12)
    alive = [thread.name for thread in threads if thread.is_alive()]
    if alive:
        cohort.abort()
        failures.append(
            {
                "worker": "cohort",
                "error_type": "Timeout",
                "sqlstate": None,
                "sqlstate_source": "runner",
                "message": "one or more contract workers did not finish",
            }
        )

    elapsed = time.time() - suite_started
    write_junit(output / "junit.xml", plan["suite_id"], results, failures, elapsed)

    attempt = {
        "suite_id": plan["suite_id"],
        "required_sessions": required,
        "peak_sessions": peak_connected,
        "completed_workers": sorted(item["worker"] for item in results),
        "failure_count": len(failures),
        "failures": failures,
        "started_ns": suite_started_ns,
        "finished_ns": time.time_ns(),
    }
    atomic_json(output / "attempt.json", attempt)

    if failures or len(results) != required or peak_connected != required:
        print(
            f"CONTRACT_COHORT_ERROR required={required} peak={peak_connected} "
            f"completed={len(results)} failures={len(failures)}",
            file=sys.stderr,
        )
        return 12

    manifest = {
        "suite_id": plan["suite_id"],
        "status": "complete",
        "database": plan["database"],
        "role": plan["role"],
        "socket": plan["socket"],
        "required_sessions": required,
        "peak_sessions": peak_connected,
        "workers": sorted(item["worker"] for item in results),
        "worker_files": sorted(f"worker_{item['worker']}.json" for item in results),
        "junit_xml": "junit.xml",
        "session_backend_pids": sorted(item["backend_pid"] for item in results),
        "cohort_started_ns": min(item["started_ns"] for item in results),
        "cohort_finished_ns": max(item["finished_ns"] for item in results),
        "errors": 0,
    }
    atomic_json(output / "manifest.json", manifest)
    print(
        f"CONTRACT_SUITE_COMPLETE suite={plan['suite_id']} sessions={required} "
        f"workers={','.join(manifest['workers'])}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
