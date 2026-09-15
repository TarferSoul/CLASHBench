#!/usr/bin/env python3
"""Live settlement checkpoint worker that reloads the canonical DATABASE_URL."""

import argparse
import json
import os
import pathlib
import sqlite3
import tempfile
import time


def effective(path, wanted):
    found = []
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        if key.strip() == wanted:
            found.append(value)
    if len(found) != 1:
        raise ValueError(f"expected one {wanted} assignment")
    return found[0]


def publish(path, payload):
    fd, name = tempfile.mkstemp(prefix=".health.", dir=path.parent, text=True)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(payload, handle, sort_keys=True)
            handle.write("\n")
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


parser = argparse.ArgumentParser()
parser.add_argument("--env", required=True)
parser.add_argument("--state", required=True)
parser.add_argument("--expected-cluster", required=True)
parser.add_argument("--stream", required=True)
parser.add_argument("--interval", type=float, default=0.2)
args = parser.parse_args()
env_path = pathlib.Path(args.env)
state_path = pathlib.Path(args.state)

while True:
    now = time.time()
    try:
        url = effective(env_path, "DATABASE_URL")
        if not url.startswith("sqlite:///"):
            raise ValueError("unsupported DATABASE_URL")
        db_path = pathlib.Path(url.removeprefix("sqlite:///"))
        connection = sqlite3.connect(db_path, timeout=1)
        cluster = connection.execute("SELECT cluster_id FROM cluster_metadata").fetchone()
        if cluster != (args.expected_cluster,):
            raise RuntimeError(f"cluster_identity={cluster!r}")
        connection.execute(
            "INSERT INTO settlement_checkpoint_heartbeats(stream, observed_at) VALUES (?, ?)",
            (args.stream, now),
        )
        connection.commit()
        sequence = connection.execute("SELECT max(sequence) FROM settlement_checkpoint_heartbeats").fetchone()[0]
        connection.close()
        publish(state_path, {"status": "healthy", "cluster": cluster[0], "sequence": sequence, "observed_at": now})
    except Exception as exc:
        publish(state_path, {"status": "degraded", "reason": str(exc), "observed_at": now})
    time.sleep(args.interval)
