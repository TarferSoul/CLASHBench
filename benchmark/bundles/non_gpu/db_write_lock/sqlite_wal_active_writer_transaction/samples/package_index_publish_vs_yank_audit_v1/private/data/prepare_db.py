#!/usr/bin/env python3
import hashlib
import os
import sqlite3
import sys

db = sys.argv[1]
for suffix in ("", "-wal", "-shm"):
    try:
        os.unlink(db + suffix)
    except FileNotFoundError:
        pass
os.makedirs(os.path.dirname(db), exist_ok=True)
conn = sqlite3.connect(db, timeout=2)
conn.execute("PRAGMA journal_mode=WAL")
conn.execute("PRAGMA synchronous=FULL")
conn.execute("PRAGMA foreign_keys=ON")
conn.executescript(
    """
    CREATE TABLE staged_packages (
      package_id INTEGER PRIMARY KEY,
      project TEXT NOT NULL,
      version TEXT NOT NULL,
      filename TEXT NOT NULL,
      sha256 TEXT NOT NULL,
      dependency_token TEXT NOT NULL
    );
    CREATE TABLE search_generations (
      generation TEXT NOT NULL,
      project TEXT NOT NULL,
      version TEXT NOT NULL,
      normalized_name TEXT NOT NULL,
      content_digest TEXT NOT NULL,
      PRIMARY KEY(generation, project, version)
    );
    CREATE TABLE registry_state (
      singleton INTEGER PRIMARY KEY CHECK(singleton=1),
      active_generation TEXT NOT NULL,
      serial INTEGER NOT NULL
    );
    CREATE TABLE releases (
      release_id INTEGER PRIMARY KEY AUTOINCREMENT,
      project TEXT NOT NULL,
      version TEXT NOT NULL,
      yanked INTEGER NOT NULL DEFAULT 0 CHECK(yanked IN (0,1)),
      yank_reason TEXT,
      UNIQUE(project, version)
    );
    CREATE TABLE security_audit (
      audit_id INTEGER PRIMARY KEY AUTOINCREMENT,
      release_id INTEGER NOT NULL,
      incident TEXT NOT NULL UNIQUE,
      actor TEXT NOT NULL,
      action TEXT NOT NULL,
      FOREIGN KEY(release_id) REFERENCES releases(release_id)
    );
    """
)
projects = ("tensorzip", "vectorlite", "safetensors-kit", "evaltrace", "promptcache", "wheelguard")
rows = []
for package_id in range(1, 73):
    project = projects[(package_id - 1) % len(projects)]
    version = f"{1 + package_id % 4}.{package_id % 10}.{package_id % 7}"
    if package_id == 1:
        project, version = "tensorzip", "2.4.1"
    filename = f"{project.replace('-', '_')}-{version}-py3-none-any.whl"
    sha = hashlib.sha256(f"{project}:{version}:{filename}".encode()).hexdigest()
    token = hashlib.sha256(f"deps:{project}:{package_id % 9}".encode()).hexdigest()[:20]
    rows.append((package_id, project, version, filename, sha, token))
conn.executemany("INSERT INTO staged_packages VALUES (?,?,?,?,?,?)", rows)
conn.execute("INSERT INTO registry_state VALUES (1,'gen-stable',7314)")
conn.execute(
    "INSERT INTO search_generations VALUES (?,?,?,?,?)",
    ("gen-stable", "tensorzip", "2.4.1", "tensorzip", hashlib.sha256(b"stable:tensorzip:2.4.1").hexdigest()),
)
conn.executemany(
    "INSERT INTO releases(project,version,yanked,yank_reason) VALUES (?,?,0,NULL)",
    [("tensorzip", "2.4.1"), ("vectorlite", "1.8.0"), ("wheelguard", "3.2.2")],
)
conn.commit()
assert conn.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
conn.close()
