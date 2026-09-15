#!/usr/bin/env python3
"""Resumable model-artifact integrity expand/backfill/contract migration."""

import argparse
import hashlib
import json
import os
import pathlib
import signal
import sqlite3
import sys
import time

PHASE_ID = "artifact_integrity_v5"
EXPAND_VERSION = "041_expand_verified_artifact_digest"
BACKFILL_VERSION = "042_backfill_verified_artifact_digest"
CONTRACT_VERSION = "043_contract_verified_artifact_digest"
CONTRACT_INDEX = "uq_model_revision_sha256"
STOP_REQUESTED = False


def utc_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def fail(message, code=1):
    print(message, file=sys.stderr, flush=True)
    raise SystemExit(code)


def connect(path):
    pathlib.Path(path).parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(path, timeout=8)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA busy_timeout=8000")
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA foreign_keys=ON")
    return con


def table_exists(con, table):
    return con.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)
    ).fetchone() is not None


def columns(con, table):
    return {row["name"]: dict(row) for row in con.execute(f"PRAGMA table_info({table})")}


def version_present(con, version):
    return con.execute("SELECT 1 FROM schema_versions WHERE version=?", (version,)).fetchone() is not None


def artifact_bytes(artifact_id):
    block = hashlib.sha256(f"model-artifact-{artifact_id:06d}-payload".encode()).digest()
    return block * (5 + artifact_id % 7)


def expected_integrity(content):
    return hashlib.sha256(content).hexdigest(), len(content)


def transformed_counts(con):
    total = int(con.execute("SELECT COUNT(*) FROM model_artifacts").fetchone()[0])
    covered = int(con.execute(
        "SELECT COUNT(*) FROM model_artifacts WHERE sha256 IS NOT NULL AND byte_size IS NOT NULL"
    ).fetchone()[0])
    checkpoint = int(con.execute(
        "SELECT COALESCE(MAX(id),0) FROM model_artifacts WHERE sha256 IS NOT NULL AND byte_size IS NOT NULL"
    ).fetchone()[0])
    return total, covered, checkpoint


def validate_rows(con, require_legacy=True):
    cols = columns(con, "model_artifacts")
    if not cols or (require_legacy and "legacy_md5" not in cols):
        return False, -1
    select = "SELECT id,model_name,revision,content,sha256,byte_size"
    if "legacy_md5" in cols:
        select += ",legacy_md5"
    select += " FROM model_artifacts ORDER BY id"
    bad = 0
    for row in con.execute(select):
        artifact_id = int(row["id"])
        content = bytes(row["content"])
        expected_sha, expected_size = expected_integrity(content)
        if content != artifact_bytes(artifact_id):
            bad += 1
            continue
        if row["model_name"] != f"model-{artifact_id % 37:02d}" or row["revision"] != f"r{artifact_id:06d}":
            bad += 1
            continue
        if row["sha256"] != expected_sha or int(row["byte_size"] or -1) != expected_size:
            bad += 1
            continue
        if "legacy_md5" in row.keys() and row["legacy_md5"] != hashlib.md5(content).hexdigest():
            bad += 1
    return bad == 0, bad


def data_proof(con):
    digest = hashlib.sha256()
    for row in con.execute("SELECT id,model_name,revision,sha256,byte_size FROM model_artifacts ORDER BY id"):
        digest.update(
            f"{row['id']}|{row['model_name']}|{row['revision']}|{row['sha256']}|{row['byte_size']}\n".encode()
        )
    return digest.hexdigest()


def phase(con):
    row = con.execute("SELECT * FROM migration_phase WHERE phase_id=?", (PHASE_ID,)).fetchone()
    if row is None:
        fail(f"PHASE_MISSING phase={PHASE_ID}", 12)
    return dict(row)


def status_payload(con):
    state = phase(con)
    total, covered, checkpoint = transformed_counts(con)
    state.update(
        observed_total=total,
        observed_covered=covered,
        observed_checkpoint=checkpoint,
        coverage_ratio=(covered / total if total else 1.0),
        contract_version_present=version_present(con, CONTRACT_VERSION),
        legacy_source_present="legacy_md5" in columns(con, "model_artifacts"),
    )
    return state


def init_database(args):
    path = pathlib.Path(args.database)
    for candidate in (path, pathlib.Path(str(path) + "-wal"), pathlib.Path(str(path) + "-shm")):
        try:
            candidate.unlink()
        except FileNotFoundError:
            pass
    con = connect(path)
    with con:
        con.executescript(
            """
            CREATE TABLE schema_versions(version TEXT PRIMARY KEY, applied_at TEXT NOT NULL, actor TEXT NOT NULL);
            CREATE TABLE migration_phase(
              phase_id TEXT PRIMARY KEY, status TEXT NOT NULL, job_id TEXT, worker_pid INTEGER,
              checkpoint INTEGER NOT NULL DEFAULT 0, total_rows INTEGER NOT NULL,
              covered_rows INTEGER NOT NULL DEFAULT 0, validation_ok INTEGER NOT NULL DEFAULT 0,
              mismatch_count INTEGER NOT NULL DEFAULT 0, heartbeat TEXT, completed_at TEXT,
              completion_proof TEXT, contract_applied_at TEXT
            );
            CREATE TABLE migration_audit(
              seq INTEGER PRIMARY KEY AUTOINCREMENT, event TEXT NOT NULL, actor TEXT NOT NULL,
              job_id TEXT, checkpoint INTEGER NOT NULL, details TEXT NOT NULL, recorded_at TEXT NOT NULL
            );
            CREATE TABLE model_artifacts(
              id INTEGER PRIMARY KEY, model_name TEXT NOT NULL, revision TEXT NOT NULL,
              media_type TEXT NOT NULL, content BLOB NOT NULL, legacy_md5 TEXT NOT NULL,
              sha256 TEXT, byte_size INTEGER
            );
            """
        )
        con.execute("INSERT INTO schema_versions VALUES(?,?,?)", (EXPAND_VERSION, utc_now(), "registry-expand"))
        con.execute(
            "INSERT INTO migration_phase(phase_id,status,total_rows,heartbeat) VALUES(?,'expanded',?,?)",
            (PHASE_ID, args.rows, utc_now()),
        )
        rows = []
        for artifact_id in range(1, args.rows + 1):
            content = artifact_bytes(artifact_id)
            rows.append((
                artifact_id, f"model-{artifact_id % 37:02d}", f"r{artifact_id:06d}",
                "application/x-safetensors", content, hashlib.md5(content).hexdigest(),
            ))
        con.executemany(
            "INSERT INTO model_artifacts(id,model_name,revision,media_type,content,legacy_md5) VALUES(?,?,?,?,?,?)",
            rows,
        )
        con.execute(
            "INSERT INTO migration_audit(event,actor,job_id,checkpoint,details,recorded_at) VALUES('expand_applied','registry-expand',NULL,0,?,?)",
            (json.dumps({"rows": args.rows}, sort_keys=True), utc_now()),
        )
    print(json.dumps(status_payload(con), sort_keys=True))


def pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, TypeError, ValueError):
        return False


def begin_backfill(con, job_id):
    state = phase(con)
    if version_present(con, CONTRACT_VERSION):
        fail("BACKFILL_REJECTED reason=contract_already_applied", 31)
    if state["status"] == "backfill_complete":
        return False
    if state.get("worker_pid") and int(state["worker_pid"]) != os.getpid() and pid_alive(state["worker_pid"]):
        fail(f"BACKFILL_ALREADY_ACTIVE job_id={state.get('job_id')} pid={state['worker_pid']}", 32)
    if state.get("job_id") not in (None, "", job_id) and int(state["covered_rows"]) > 0:
        fail(f"BACKFILL_OWNER_MISMATCH expected={state['job_id']} supplied={job_id}", 33)
    total, covered, checkpoint = transformed_counts(con)
    with con:
        con.execute(
            "UPDATE migration_phase SET status='backfill_running',job_id=?,worker_pid=?,checkpoint=?,total_rows=?,covered_rows=?,heartbeat=? WHERE phase_id=?",
            (job_id, os.getpid(), checkpoint, total, covered, utc_now(), PHASE_ID),
        )
        con.execute(
            "INSERT INTO migration_audit(event,actor,job_id,checkpoint,details,recorded_at) VALUES('backfill_started','artifact-integrity-worker',?,?,?,?)",
            (job_id, checkpoint, json.dumps({"pid": os.getpid()}), utc_now()),
        )
    return True


def process_batch(con, job_id, batch_size):
    rows = con.execute(
        "SELECT id,content FROM model_artifacts WHERE sha256 IS NULL OR byte_size IS NULL ORDER BY id LIMIT ?",
        (batch_size,),
    ).fetchall()
    if not rows:
        return 0
    values = []
    for row in rows:
        digest, size = expected_integrity(bytes(row["content"]))
        values.append((digest, size, int(row["id"])))
    with con:
        con.executemany("UPDATE model_artifacts SET sha256=?,byte_size=? WHERE id=?", values)
        total, covered, checkpoint = transformed_counts(con)
        con.execute(
            "UPDATE migration_phase SET worker_pid=?,checkpoint=?,total_rows=?,covered_rows=?,heartbeat=? WHERE phase_id=? AND job_id=?",
            (os.getpid(), checkpoint, total, covered, utc_now(), PHASE_ID, job_id),
        )
        con.execute(
            "INSERT INTO migration_audit(event,actor,job_id,checkpoint,details,recorded_at) VALUES('batch_committed','artifact-integrity-worker',?,?,?,?)",
            (job_id, checkpoint, json.dumps({"batch": len(values)}), utc_now()),
        )
    return len(values)


def complete_backfill(con, job_id):
    total, covered, checkpoint = transformed_counts(con)
    valid, bad = validate_rows(con, require_legacy=True)
    if covered != total or not valid:
        fail(f"BACKFILL_VALIDATION_FAILED covered={covered} total={total} bad={bad}", 34)
    proof = data_proof(con)
    with con:
        con.execute("INSERT OR IGNORE INTO schema_versions VALUES(?,?,?)", (BACKFILL_VERSION, utc_now(), job_id))
        con.execute(
            "UPDATE migration_phase SET status='backfill_complete',worker_pid=?,checkpoint=?,covered_rows=?,validation_ok=1,mismatch_count=0,heartbeat=?,completed_at=?,completion_proof=? WHERE phase_id=? AND job_id=?",
            (os.getpid(), checkpoint, covered, utc_now(), utc_now(), proof, PHASE_ID, job_id),
        )
        con.execute(
            "INSERT INTO migration_audit(event,actor,job_id,checkpoint,details,recorded_at) VALUES('backfill_completed','artifact-integrity-worker',?,?,?,?)",
            (job_id, checkpoint, json.dumps({"proof": proof}), utc_now()),
        )
    print(f"BACKFILL_COMPLETE job_id={job_id} checkpoint={checkpoint} proof={proof}", flush=True)


def on_signal(_signum, _frame):
    global STOP_REQUESTED
    STOP_REQUESTED = True


def run_backfill(args):
    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)
    con = connect(args.database)
    if not begin_backfill(con, args.job_id):
        print(f"BACKFILL_ALREADY_COMPLETE job_id={args.job_id}")
        return
    print(f"BACKFILL_STARTED job_id={args.job_id} pid={os.getpid()}", flush=True)
    while not STOP_REQUESTED:
        changed = process_batch(con, args.job_id, args.batch_size)
        state = status_payload(con)
        print(
            f"BACKFILL_PROGRESS job_id={args.job_id} checkpoint={state['observed_checkpoint']} covered={state['observed_covered']} total={state['observed_total']}",
            flush=True,
        )
        if changed == 0:
            complete_backfill(con, args.job_id)
            return
        time.sleep(args.interval)
    print(f"BACKFILL_STOPPED job_id={args.job_id}", flush=True)


def gate_reason(con):
    for table in ("schema_versions", "migration_phase", "migration_audit", "model_artifacts"):
        if not table_exists(con, table):
            return f"destructive_missing_{table}"
    required = {"legacy_md5", "content", "sha256", "byte_size"}
    if not required.issubset(columns(con, "model_artifacts")):
        return "destructive_schema_change"
    state = phase(con)
    total, covered, checkpoint = transformed_counts(con)
    valid, bad = validate_rows(con, require_legacy=True)
    if state["status"] != "backfill_complete":
        return f"phase_{state['status']}"
    if int(state["validation_ok"]) != 1 or int(state["mismatch_count"]) != 0:
        return "validation_not_clean"
    if covered != total or int(state["covered_rows"]) != total or int(state["checkpoint"]) != checkpoint:
        return "coverage_incomplete"
    if not valid:
        return f"blob_integrity_failed_{bad}"
    if not version_present(con, BACKFILL_VERSION):
        return "backfill_version_missing"
    if state.get("completion_proof") != data_proof(con):
        return "completion_proof_mismatch"
    audit = con.execute(
        "SELECT details FROM migration_audit WHERE event='backfill_completed' AND job_id=? ORDER BY seq DESC LIMIT 1",
        (state.get("job_id"),),
    ).fetchone()
    if audit is None or state["completion_proof"] not in audit["details"]:
        return "completion_audit_missing"
    return None


def apply_contract(args):
    con = connect(args.database)
    reason = gate_reason(con)
    if reason:
        state = phase(con)
        print(
            f"PHASE_GATE_REJECTED phase={PHASE_ID} reason={reason} status={state['status']} checkpoint={state['checkpoint']} covered={state['covered_rows']} total={state['total_rows']}",
            file=sys.stderr,
        )
        raise SystemExit(23)
    con.execute("BEGIN IMMEDIATE")
    try:
        reason = gate_reason(con)
        if reason:
            raise RuntimeError(f"phase changed during contract: {reason}")
        state = phase(con)
        con.execute(
            "CREATE TABLE model_artifacts_contract(id INTEGER PRIMARY KEY,model_name TEXT NOT NULL,revision TEXT NOT NULL,media_type TEXT NOT NULL,content BLOB NOT NULL,sha256 TEXT NOT NULL CHECK(length(sha256)=64),byte_size INTEGER NOT NULL CHECK(byte_size>0))"
        )
        con.execute(
            "INSERT INTO model_artifacts_contract SELECT id,model_name,revision,media_type,content,sha256,byte_size FROM model_artifacts ORDER BY id"
        )
        con.execute("DROP TABLE model_artifacts")
        con.execute("ALTER TABLE model_artifacts_contract RENAME TO model_artifacts")
        con.execute("CREATE UNIQUE INDEX uq_model_revision_sha256 ON model_artifacts(model_name,revision,sha256)")
        con.execute("INSERT INTO schema_versions VALUES(?,?,?)", (CONTRACT_VERSION, utc_now(), "agentb-contract"))
        con.execute(
            "UPDATE migration_phase SET status='contract_applied',contract_applied_at=? WHERE phase_id=?",
            (utc_now(), PHASE_ID),
        )
        con.execute(
            "INSERT INTO migration_audit(event,actor,job_id,checkpoint,details,recorded_at) VALUES('contract_applied','agentb-contract',?,?,?,?)",
            (state["job_id"], state["checkpoint"], json.dumps({"version": CONTRACT_VERSION, "proof": state["completion_proof"]}), utc_now()),
        )
        con.commit()
    except Exception:
        con.rollback()
        raise
    verified = verify_payload(con)
    if not verified["ok"]:
        fail(f"CONTRACT_VERIFY_FAILED details={json.dumps(verified, sort_keys=True)}", 24)
    report = {
        "database": args.database,
        "phase_id": PHASE_ID,
        "schema_head": CONTRACT_VERSION,
        "contract_index": CONTRACT_INDEX,
        "verified": True,
        "row_count": verified["row_count"],
        "verified_bytes": verified["verified_bytes"],
        "applied_at": utc_now(),
    }
    if args.report:
        target = pathlib.Path(args.report)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report, sort_keys=True))


def verify_payload(con):
    cols = columns(con, "model_artifacts")
    indexes = {row["name"] for row in con.execute("PRAGMA index_list(model_artifacts)")}
    state = phase(con)
    valid, bad = validate_rows(con, require_legacy=False)
    row_count = int(con.execute("SELECT COUNT(*) FROM model_artifacts").fetchone()[0])
    verified_bytes = int(con.execute("SELECT COALESCE(SUM(byte_size),0) FROM model_artifacts").fetchone()[0])
    history = [row[0] for row in con.execute("SELECT version FROM schema_versions ORDER BY version")]
    ok = all((
        version_present(con, CONTRACT_VERSION), state["status"] == "contract_applied",
        "legacy_md5" not in cols,
        cols.get("sha256", {}).get("notnull") == 1,
        cols.get("byte_size", {}).get("notnull") == 1,
        CONTRACT_INDEX in indexes, valid, row_count == int(state["total_rows"]),
        history == [EXPAND_VERSION, BACKFILL_VERSION, CONTRACT_VERSION],
    ))
    return {
        "ok": bool(ok), "row_count": row_count, "verified_bytes": verified_bytes,
        "bad_rows": bad, "columns": sorted(cols), "indexes": sorted(indexes),
        "history": history, "phase_status": state["status"],
    }


def verify_contract(args):
    payload = verify_payload(connect(args.database))
    print(json.dumps(payload, sort_keys=True))
    raise SystemExit(0 if payload["ok"] else 25)


def show_status(args):
    print(json.dumps(status_payload(connect(args.database)), sort_keys=True))


def parser():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="command", required=True)
    init = sub.add_parser("init")
    init.add_argument("--database", required=True)
    init.add_argument("--rows", required=True, type=int)
    init.set_defaults(func=init_database)
    backfill = sub.add_parser("backfill")
    backfill.add_argument("--database", required=True)
    backfill.add_argument("--job-id", required=True)
    backfill.add_argument("--batch-size", type=int, default=8)
    backfill.add_argument("--interval", type=float, default=0.25)
    backfill.set_defaults(func=run_backfill)
    status = sub.add_parser("status")
    status.add_argument("--database", required=True)
    status.set_defaults(func=show_status)
    contract = sub.add_parser("apply-contract")
    contract.add_argument("--database", required=True)
    contract.add_argument("--report")
    contract.set_defaults(func=apply_contract)
    verify = sub.add_parser("verify-contract")
    verify.add_argument("--database", required=True)
    verify.set_defaults(func=verify_contract)
    return ap


def main():
    args = parser().parse_args()
    if getattr(args, "rows", 1) < 1 or getattr(args, "batch_size", 1) < 1:
        fail("rows and batch size must be positive", 2)
    args.func(args)


if __name__ == "__main__":
    main()
