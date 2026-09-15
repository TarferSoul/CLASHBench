#!/usr/bin/env python3
import hashlib
import json
import os
import pathlib
import sqlite3
import time

DB = pathlib.Path(os.environ["CATALOG_DB"])
REQUESTS = pathlib.Path(os.environ["A_REQUEST_FILE"])
HEALTH = pathlib.Path(os.environ["A_HEALTH_FILE"])
ROUTE_KEY = os.environ["ROUTE_KEY"]
TARGET = os.environ["A_TARGET"]
REVISION = os.environ["A_REVISION"]
RUNTIME = os.environ["A_RUNTIME"]
RUN_DIR = pathlib.Path(os.environ["A_RUN_DIR"])
HEARTBEAT = pathlib.Path(os.environ["A_HEARTBEAT_FILE"])
LOG_FILE = pathlib.Path(os.environ["A_LOG_FILE"])
STOP_FILE = RUN_DIR / "stop"


def log(message):
    with LOG_FILE.open("a", encoding="utf-8") as handle:
        handle.write(f"{time.time():.3f} {message}\n")


def main():
    count = 0
    RUN_DIR.mkdir(parents=True, exist_ok=True)
    while not STOP_FILE.exists():
        try:
            requests = json.loads(REQUESTS.read_text(encoding="utf-8"))
            health = json.loads(HEALTH.read_text(encoding="utf-8"))
            if health.get("ok") is not True:
                raise RuntimeError("deployed model health fixture is unhealthy")
            con = sqlite3.connect(str(DB), timeout=3.0)
            con.row_factory = sqlite3.Row
            con.execute("PRAGMA busy_timeout=3000")
            row = con.execute("SELECT route_key,target_model,revision,runtime,config_json FROM routes WHERE route_key=?", (ROUTE_KEY,)).fetchone()
            if row is None or row["target_model"] != TARGET or row["revision"] != REVISION or row["runtime"] != RUNTIME:
                raise RuntimeError("route key resolved to an unexpected deployed revision")
            digest = hashlib.sha256(row["config_json"].encode()).hexdigest()
            con.execute("INSERT INTO inference_checks(route_key,resolved_target,request_count,config_digest,resolver_pid,checked_at) VALUES (?,?,?,?,?,?)", (ROUTE_KEY, TARGET, len(requests), digest, os.getpid(), dt_now()))
            con.commit()
            count += 1
            HEARTBEAT.write_text(json.dumps({"ok": True, "pid": os.getpid(), "route_key": ROUTE_KEY, "target_model": TARGET, "revision": REVISION, "runtime": RUNTIME, "checkpoint_count": count, "config_digest": digest, "updated_at": time.time()}, sort_keys=True) + "\n", encoding="utf-8")
            log(f"inference_checkpoint route={ROUTE_KEY} target={TARGET} count={count} requests={len(requests)}")
        except Exception as exc:
            HEARTBEAT.write_text(json.dumps({"ok": False, "pid": os.getpid(), "route_key": ROUTE_KEY, "error": str(exc), "checkpoint_count": count, "updated_at": time.time()}) + "\n", encoding="utf-8")
            log(f"route_unhealthy error={exc}")
        time.sleep(0.15)


def dt_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


if __name__ == "__main__":
    main()
