#!/usr/bin/env python3
import json
import sqlite3
import sys

db, receipt = sys.argv[1:3]
try:
    conn = sqlite3.connect(db, timeout=.25, isolation_level=None)
    conn.execute("PRAGMA busy_timeout=250")
    conn.execute("PRAGMA foreign_keys=ON")
    conn.execute("BEGIN IMMEDIATE")
    row = conn.execute(
        "SELECT release_id FROM releases WHERE project=? AND version=?",
        ("tensorzip", "2.4.1"),
    ).fetchone()
    if row is None:
        raise RuntimeError("release not found")
    release_id = int(row[0])
    conn.execute(
        "UPDATE releases SET yanked=1,yank_reason=? WHERE release_id=?",
        ("malformed wheel metadata", release_id),
    )
    cur = conn.execute(
        "INSERT INTO security_audit(release_id,incident,actor,action) VALUES (?,?,?,?)",
        (release_id, "SEC-2026-804", "supply-chain-sre", "release_yanked"),
    )
    audit_id = cur.lastrowid
    conn.commit()
except sqlite3.OperationalError as exc:
    try:
        conn.rollback()
    except Exception:
        pass
    if "locked" in str(exc).lower() or "busy" in str(exc).lower():
        print(f"B_COMMIT=0 SQLITE_BUSY=1 error={str(exc).replace(' ', '_')}")
        raise SystemExit(75)
    raise
finally:
    try:
        conn.close()
    except Exception:
        pass

with sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=.25) as verify:
    fresh = verify.execute(
        "SELECT r.project,r.version,r.release_id,a.audit_id,r.yanked,r.yank_reason,a.incident,a.actor,a.action "
        "FROM releases r JOIN security_audit a ON a.release_id=r.release_id "
        "WHERE r.project=? AND r.version=? AND a.incident=?",
        ("tensorzip", "2.4.1", "SEC-2026-804"),
    ).fetchone()
expected = ("tensorzip", "2.4.1", release_id, audit_id, 1, "malformed wheel metadata", "SEC-2026-804", "supply-chain-sre", "release_yanked")
if fresh != expected:
    raise SystemExit(f"fresh verification mismatch: {fresh!r}")
payload = dict(zip(
    ("project", "version", "release_id", "audit_id", "yanked", "yank_reason", "incident", "actor", "action"),
    fresh,
))
with open(receipt, "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True)
    handle.write("\n")
print(f"B_COMMIT=1 release_id={release_id} audit_id={audit_id} fresh_verify=1")
