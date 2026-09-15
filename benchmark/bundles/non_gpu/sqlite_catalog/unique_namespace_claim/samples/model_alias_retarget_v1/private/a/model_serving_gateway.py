#!/usr/bin/env python3
import hashlib
import json
import os
import pathlib
import sqlite3
import time

DB = pathlib.Path(os.environ["CATALOG_DB"])
REQUESTS = pathlib.Path(os.environ["MODEL_REQUEST_FILE"])
HEALTH = pathlib.Path(os.environ["MODEL_HEALTH_FILE"])
TENANT = os.environ["A_TENANT"]
ALIAS = os.environ["A_ALIAS"]
MODEL_ID = os.environ["A_MODEL_ID"]
MODEL_KIND = os.environ["A_MODEL_KIND"]
MODEL_VERSION = os.environ["A_MODEL_VERSION"]
HEARTBEAT = pathlib.Path(os.environ["A_HEARTBEAT_FILE"])
LOG_FILE = pathlib.Path(os.environ["A_LOG_FILE"])
STOP_FILE = pathlib.Path(os.environ["A_RUN_DIR"]) / "stop"

def log(message):
    with LOG_FILE.open("a", encoding="utf-8") as handle:
        handle.write(f"{time.time():.3f} {message}\n")

def main():
    HEARTBEAT.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    while not STOP_FILE.exists():
        try:
            requests = json.loads(REQUESTS.read_text(encoding="utf-8"))
            health = json.loads(HEALTH.read_text(encoding="utf-8"))
            if health.get("ok") is not True:
                raise RuntimeError("model health endpoint is not healthy")
            con = sqlite3.connect(str(DB), timeout=2.0)
            con.row_factory = sqlite3.Row
            row = con.execute("SELECT model_id, tenant_id, alias, model_kind, version, config_json FROM models WHERE tenant_id=? AND alias=?", (TENANT, ALIAS)).fetchone()
            if row is None or row["model_id"] != MODEL_ID or row["model_kind"] != MODEL_KIND or row["version"] != MODEL_VERSION:
                raise RuntimeError("model alias resolved to an unexpected revision")
            digest = hashlib.sha256(row["config_json"].encode()).hexdigest()
            con.execute("INSERT INTO inference_runs(model_id, tenant_id, alias, request_count, config_digest, resolver_pid, checkpoint_at) VALUES (?,?,?,?,?,?,datetime('now'))", (MODEL_ID, TENANT, ALIAS, len(requests), digest, os.getpid()))
            con.commit()
            count += 1
            HEARTBEAT.write_text(json.dumps({"ok": True, "pid": os.getpid(), "tenant_id": TENANT, "alias": ALIAS, "model_id": MODEL_ID, "model_kind": MODEL_KIND, "version": MODEL_VERSION, "checkpoint_count": count, "config_digest": digest, "updated_at": time.time()}, sort_keys=True) + "\n", encoding="utf-8")
            log(f"inference_checkpoint model={MODEL_ID} count={count} requests={len(requests)}")
        except Exception as exc:
            HEARTBEAT.write_text(json.dumps({"ok": False, "pid": os.getpid(), "error": str(exc), "updated_at": time.time()}) + "\n", encoding="utf-8")
            log(f"unhealthy error={exc}")
        time.sleep(0.16)

if __name__ == "__main__":
    main()
