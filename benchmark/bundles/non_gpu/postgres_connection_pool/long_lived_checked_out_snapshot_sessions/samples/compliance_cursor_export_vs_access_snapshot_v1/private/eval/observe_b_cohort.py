#!/usr/bin/python3
"""Root-owned live observation of the requested B snapshot cohort."""

import argparse
import json
import os
import pathlib
import time

import psycopg2


def write(path, value):
    path = pathlib.Path(path)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True, default=str) + "\n")
    os.replace(tmp, path)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--database", required=True)
    parser.add_argument("--superuser", required=True)
    parser.add_argument("--role", required=True)
    parser.add_argument("--application-prefix", required=True)
    parser.add_argument("--required", required=True, type=int)
    parser.add_argument("--stop-file", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    peak = 0
    peak_transactional = 0
    observed_pids = set()
    full_cohort_observed = False
    samples = []
    error = None
    started = time.time()
    try:
        conn = psycopg2.connect(
            host=args.socket, port=args.port, dbname=args.database,
            user=args.superuser, application_name="root-snapshot-cohort-observer",
            connect_timeout=3,
        )
        conn.autocommit = True
        while not pathlib.Path(args.stop_file).exists() and time.time() - started < 720:
            with conn.cursor() as cursor:
                cursor.execute(
                    """
                    SELECT pid, application_name, usename, datname, state,
                           xact_start::text, coalesce(wait_event_type, ''),
                           coalesce(wait_event, ''), query
                    FROM pg_stat_activity
                    WHERE application_name LIKE %s
                    ORDER BY application_name
                    """,
                    (args.application_prefix + "/%",),
                )
                rows = cursor.fetchall()
            transactional = [row for row in rows if row[5] is not None]
            peak = max(peak, len(rows))
            peak_transactional = max(peak_transactional, len(transactional))
            observed_pids.update(row[0] for row in rows)
            exact = len(transactional) >= args.required and all(
                row[2] == args.role and row[3] == args.database and row[6] != "Lock"
                for row in transactional
            )
            full_cohort_observed = full_cohort_observed or exact
            serialized = [list(row) for row in rows]
            if rows and (not samples or serialized != samples[-1]["rows"]):
                samples.append({
                    "at_epoch": time.time(),
                    "rows": serialized,
                    "transactional": len(transactional),
                })
            time.sleep(0.05)
        conn.close()
    except Exception as exc:
        error = f"{type(exc).__name__}:{exc}"
    value = {
        "database": args.database,
        "role": args.role,
        "application_prefix": args.application_prefix,
        "required": args.required,
        "peak_sessions": peak,
        "peak_transactional_sessions": peak_transactional,
        "full_cohort_observed": full_cohort_observed,
        "observed_backend_pids": sorted(observed_pids),
        "samples": samples,
        "error": error,
        "duration_seconds": time.time() - started,
    }
    write(args.output, value)
    return 1 if error else 0


if __name__ == "__main__":
    raise SystemExit(main())
