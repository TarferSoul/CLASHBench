#!/usr/bin/env python3
"""Exclusive feature-schema generation publisher using the fixed lease scripts."""

import argparse
import hashlib
import json
import os
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "lib"))
import redis_rwlock  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--deadline", type=float, default=4.0)
    ap.add_argument("--label", default="writer")
    ap.add_argument("--artifact", required=True)
    args = ap.parse_args()
    artifact = Path(args.artifact)
    artifact.parent.mkdir(parents=True, exist_ok=True)
    token = redis_rwlock.token(args.label)
    r = redis_rwlock.conn()
    attempts = 0
    acquired = False
    started = time.time()
    try:
        until = time.monotonic() + args.deadline
        while time.monotonic() < until:
            attempts += 1
            if redis_rwlock.acquire_write(r, token, int(os.environ["WRITER_TTL_SECONDS"])):
                acquired = True
                break
            time.sleep(0.1)
        if not acquired:
            result = {"acquired": False, "attempts": attempts, "elapsed_ms": int((time.time() - started) * 1000), "reason": "readers_active_or_writer_busy"}
            artifact.write_text(json.dumps(result, sort_keys=True) + "\n")
            print(json.dumps(result, sort_keys=True))
            return 0
        old_generation = r.command("GET", os.environ["ACTIVE_KEY"])
        if old_generation != "schema_v1":
            raise RuntimeError(f"unexpected active generation {old_generation!r}")
        payload = Path(os.environ["DATA_ROOT"], "schema_v2.json").read_text()
        digest = hashlib.sha256(payload.encode()).hexdigest()
        r.command("SET", os.environ["GENERATION_PREFIX"] + "schema_v2", payload)
        epoch = int(r.command("INCR", os.environ["FENCE_KEY"]))
        r.command("SET", os.environ["ACTIVE_KEY"], "schema_v2")
        result = {"acquired": True, "generation": "schema_v2", "fencing_epoch": epoch, "digest": digest, "owner": token, "attempts": attempts}
        artifact.write_text(json.dumps(result, sort_keys=True) + "\n")
        if not redis_rwlock.release_write(r, token):
            raise RuntimeError("owner-checked writer release failed")
        print(json.dumps(result, sort_keys=True))
        return 0
    finally:
        if acquired:
            redis_rwlock.release_write(r, token)
        r.close()


if __name__ == "__main__":
    raise SystemExit(main())
