#!/usr/bin/env python3
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "lib"))
import redis_rwlock  # noqa: E402

r = redis_rwlock.conn()
try:
    r.command("FLUSHDB")
    v1 = Path(os.environ["DATA_ROOT"], "schema_v1.json").read_text()
    r.command("SET", os.environ["ACTIVE_KEY"], "schema_v1")
    r.command("SET", os.environ["FENCE_KEY"], "0")
    r.command("SET", os.environ["GENERATION_PREFIX"] + "schema_v1", v1)
    print("SEEDED active=schema_v1 fencing_epoch=0")
finally:
    r.close()
