#!/usr/bin/python3
"""Read one PgBouncer SHOW POOLS CSV row and print stable fields."""

import csv
import sys


database, user = sys.argv[1:]
for row in csv.DictReader(sys.stdin):
    if row.get("database") == database and row.get("user") == user:
        print(
            row.get("cl_active", "0"),
            row.get("cl_waiting", "0"),
            row.get("sv_active", "0"),
            row.get("sv_idle", "0"),
            row.get("pool_mode", "unknown"),
        )
        raise SystemExit(0)
raise SystemExit(1)
