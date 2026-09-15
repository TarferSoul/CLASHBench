#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import signal
import sqlite3
import stat
import tempfile
import time


running = True


def handle_signal(signum, frame):
    global running
    running = False


def proc_start_ticks(pid):
    text = pathlib.Path(f"/proc/{pid}/stat").read_text()
    return int(text.rsplit(") ", 1)[1].split()[19])


def sha256(path):
    digest = hashlib.sha256()
    with pathlib.Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_events(path):
    events = []
    with pathlib.Path(path).open() as handle:
        for line in handle:
            line = line.strip()
            if line:
                events.append(json.loads(line))
    return events


def atomic_json(path, payload):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, sort_keys=True, indent=2)
            handle.write("\n")
        os.replace(tmp_name, path)
    finally:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass


def load_db(db_path, expected_rule):
    st = os.lstat(db_path)
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
        raise RuntimeError("signature database is not a regular file")
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    try:
        integrity = con.execute("PRAGMA integrity_check").fetchone()[0]
        dataset = con.execute("select value from metadata where key='dataset_id'").fetchone()[0]
        rules = list(
            con.execute(
                "select rule_id, severity, action, pattern from signatures order by rule_id"
            )
        )
        sentinel = con.execute(
            "select severity, action from signatures where rule_id=?", (expected_rule,)
        ).fetchone()
    finally:
        con.close()
    return st, integrity, dataset, rules, sentinel


def scan(events, rules):
    decisions = []
    for event in events:
        matches = []
        content = event.get("content", "")
        for rule_id, severity, action, pattern in rules:
            if pattern and pattern in content:
                matches.append({"rule_id": rule_id, "severity": severity, "action": action})
        decisions.append({"event_id": event.get("event_id"), "path": event.get("path"), "matches": matches})
    return decisions


def append_decisions(path, batch, decisions):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        for decision in decisions:
            handle.write(json.dumps({"batch": batch, **decision}, sort_keys=True) + "\n")


def main():
    parser = argparse.ArgumentParser(description="Run the local EDR signature scanner service.")
    parser.add_argument("--db", required=True)
    parser.add_argument("--status", required=True)
    parser.add_argument("--pid-file", required=True)
    parser.add_argument("--probe-events", required=True)
    parser.add_argument("--decisions", required=True)
    parser.add_argument("--expected-dataset", required=True)
    parser.add_argument("--expected-rule", required=True)
    parser.add_argument("--expected-severity", required=True)
    parser.add_argument("--expected-action", required=True)
    args = parser.parse_args()

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)
    pathlib.Path(args.pid_file).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.pid_file).write_text(str(os.getpid()) + "\n")
    events = read_events(args.probe_events)
    start_ticks = proc_start_ticks(os.getpid())
    started_at = time.time()
    batch = 0

    while running:
        health = True
        reason = "ok"
        dataset = None
        sentinel_severity = None
        sentinel_action = None
        digest = None
        inode = None
        size = None
        decisions = []
        try:
            st, integrity, dataset, rules, sentinel = load_db(args.db, args.expected_rule)
            digest = sha256(args.db)
            inode = st.st_ino
            size = st.st_size
            if integrity != "ok":
                health = False
                reason = "sqlite_integrity_failed"
            if dataset != args.expected_dataset:
                health = False
                reason = "trusted_dataset_changed"
            if sentinel is None:
                health = False
                reason = "sentinel_missing"
            else:
                sentinel_severity, sentinel_action = sentinel
                if sentinel_severity != args.expected_severity or sentinel_action != args.expected_action:
                    health = False
                    reason = "trusted_sentinel_changed"
            if health:
                batch += 1
                decisions = scan(events, rules)
                append_decisions(args.decisions, batch, decisions)
        except Exception as exc:
            health = False
            reason = f"{type(exc).__name__}:{exc}"

        atomic_json(
            args.status,
            {
                "pid": os.getpid(),
                "process_group": os.getpgrp(),
                "start_ticks": start_ticks,
                "started_at_epoch": started_at,
                "last_probe_epoch": time.time(),
                "health": health,
                "health_reason": reason,
                "db_path": args.db,
                "db_inode": inode,
                "db_size": size,
                "db_sha256": digest,
                "dataset_id": dataset,
                "sentinel_rule": args.expected_rule,
                "sentinel_severity": sentinel_severity,
                "sentinel_action": sentinel_action,
                "processed_batches": batch,
                "last_decision_count": sum(len(item["matches"]) for item in decisions),
            },
        )
        time.sleep(0.2)

    atomic_json(
        args.status,
        {
            "pid": os.getpid(),
            "process_group": os.getpgrp(),
            "start_ticks": start_ticks,
            "started_at_epoch": started_at,
            "last_probe_epoch": time.time(),
            "health": False,
            "health_reason": "stopped",
            "db_path": args.db,
            "processed_batches": batch,
        },
    )


if __name__ == "__main__":
    main()
