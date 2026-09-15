#!/usr/bin/env python3
import argparse
import json
import pathlib
import secrets
import sqlite3
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


DB_LOCK = threading.RLock()


def now():
    return time.time()


def iso(ts=None):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now() if ts is None else ts))


def connect(db_path):
    db = sqlite3.connect(db_path, timeout=5.0, isolation_level=None)
    db.row_factory = sqlite3.Row
    return db


def init_db(db_path):
    path = pathlib.Path(db_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with connect(path) as db:
        db.executescript(
            """
            create table if not exists sessions (
              session_id text primary key,
              owner text not null,
              ttl_seconds integer not null,
              created_at real not null,
              renewed_at real not null,
              renew_count integer not null,
              active integer not null
            );
            create table if not exists locks (
              state_key text primary key,
              session_id text not null,
              owner text not null,
              acquired_at real not null,
              renewed_at real not null,
              expires_at real not null,
              lock_index integer not null
            );
            create table if not exists states (
              state_key text primary key,
              lineage text not null,
              serial integer not null,
              state_json text not null,
              updated_by text not null,
              updated_at real not null
            );
            create table if not exists history (
              id integer primary key autoincrement,
              ts real not null,
              event text not null,
              state_key text,
              session_id text,
              owner text,
              detail text
            );
            """
        )


def log_event(db, event, state_key=None, session_id=None, owner=None, detail=None):
    db.execute(
        "insert into history(ts,event,state_key,session_id,owner,detail) values(?,?,?,?,?,?)",
        (now(), event, state_key, session_id, owner, json.dumps(detail or {}, sort_keys=True)),
    )


def row_to_dict(row):
    if row is None:
        return None
    value = dict(row)
    for key in ("created_at", "renewed_at", "acquired_at", "expires_at", "updated_at", "ts"):
        if key in value and value[key] is not None:
            value[key + "_iso"] = iso(float(value[key]))
    return value


def active_lock(db, state_key):
    row = db.execute("select * from locks where state_key=?", (state_key,)).fetchone()
    if row is None:
        return None
    lock = dict(row)
    if float(lock["expires_at"]) <= now():
        db.execute("delete from locks where state_key=?", (state_key,))
        log_event(
            db,
            "lock_expired",
            state_key=state_key,
            session_id=lock["session_id"],
            owner=lock["owner"],
            detail={"expires_at": lock["expires_at"]},
        )
        return None
    session = db.execute(
        "select active from sessions where session_id=?", (lock["session_id"],)
    ).fetchone()
    if session is None or int(session["active"]) != 1:
        db.execute("delete from locks where state_key=?", (state_key,))
        log_event(
            db,
            "lock_orphan_reaped",
            state_key=state_key,
            session_id=lock["session_id"],
            owner=lock["owner"],
        )
        return None
    return row_to_dict(row)


class Handler(BaseHTTPRequestHandler):
    server_version = "FeatureStoreStateBackend/1.0"

    def _json(self, status, value):
        payload = json.dumps(value, sort_keys=True).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _body(self):
        length = int(self.headers.get("content-length") or "0")
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        return json.loads(raw.decode() or "{}")

    def _query(self):
        parsed = urllib.parse.urlparse(self.path)
        return parsed.path, urllib.parse.parse_qs(parsed.query)

    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        path, query = self._query()
        with DB_LOCK, connect(self.server.db_path) as db:
            if path == "/health":
                self._json(200, {"ok": True, "time": iso()})
                return
            if path == "/v1/session/list":
                rows = db.execute(
                    "select * from sessions order by created_at, session_id"
                ).fetchall()
                self._json(200, [row_to_dict(row) for row in rows])
                return
            if path.startswith("/v1/session/info/"):
                session_id = urllib.parse.unquote(path.rsplit("/", 1)[-1])
                row = db.execute(
                    "select * from sessions where session_id=?", (session_id,)
                ).fetchone()
                self._json(200 if row else 404, {"session": row_to_dict(row)})
                return
            if path == "/v1/lock/current":
                state_key = query.get("key", [""])[0]
                self._json(200, {"lock": active_lock(db, state_key)})
                return
            if path == "/v1/lock/history":
                state_key = query.get("key", [""])[0]
                rows = db.execute(
                    "select * from history where state_key=? order by id",
                    (state_key,),
                ).fetchall()
                self._json(200, {"history": [row_to_dict(row) for row in rows]})
                return
            if path == "/v1/state":
                state_key = query.get("key", [""])[0]
                row = db.execute(
                    "select * from states where state_key=?", (state_key,)
                ).fetchone()
                if row is None:
                    self._json(404, {"error": "state_not_found"})
                    return
                state = json.loads(row["state_json"])
                self._json(
                    200,
                    {
                        "lineage": row["lineage"],
                        "serial": row["serial"],
                        "updated_by": row["updated_by"],
                        "updated_at": row_to_dict(row)["updated_at_iso"],
                        "state": state,
                    },
                )
                return
        self._json(404, {"error": "not_found"})

    def do_POST(self):
        path, _ = self._query()
        body = self._body()
        with DB_LOCK, connect(self.server.db_path) as db:
            if path == "/v1/session/create":
                owner = str(body.get("owner") or "unknown")
                ttl = int(body.get("ttl_seconds") or self.server.default_ttl)
                session_id = "fs-" + secrets.token_hex(12)
                db.execute(
                    "insert into sessions values(?,?,?,?,?,?,?)",
                    (session_id, owner, ttl, now(), now(), 0, 1),
                )
                log_event(db, "session_create", session_id=session_id, owner=owner)
                self._json(
                    200,
                    {
                        "session_id": session_id,
                        "owner": owner,
                        "ttl_seconds": ttl,
                        "create_index": session_id[-8:],
                    },
                )
                return
            if path.startswith("/v1/session/renew/"):
                session_id = urllib.parse.unquote(path.rsplit("/", 1)[-1])
                row = db.execute(
                    "select * from sessions where session_id=? and active=1",
                    (session_id,),
                ).fetchone()
                if row is None:
                    self._json(404, {"error": "session_not_active"})
                    return
                ts = now()
                db.execute(
                    "update sessions set renewed_at=?, renew_count=renew_count+1 where session_id=?",
                    (ts, session_id),
                )
                db.execute(
                    "update locks set renewed_at=?, expires_at=? where session_id=?",
                    (ts, ts + int(row["ttl_seconds"]), session_id),
                )
                lock_rows = db.execute(
                    "select state_key from locks where session_id=?", (session_id,)
                ).fetchall()
                for lock_row in lock_rows:
                    log_event(
                        db,
                        "session_renew",
                        state_key=lock_row["state_key"],
                        session_id=session_id,
                        owner=row["owner"],
                    )
                self._json(
                    200,
                    {"session_id": session_id, "owner": row["owner"], "renewed_at": iso(ts)},
                )
                return
            if path.startswith("/v1/session/destroy/"):
                session_id = urllib.parse.unquote(path.rsplit("/", 1)[-1])
                row = db.execute(
                    "select * from sessions where session_id=?", (session_id,)
                ).fetchone()
                lock_rows = db.execute(
                    "select * from locks where session_id=?", (session_id,)
                ).fetchall()
                db.execute("update sessions set active=0 where session_id=?", (session_id,))
                db.execute("delete from locks where session_id=?", (session_id,))
                for lock_row in lock_rows:
                    log_event(
                        db,
                        "lock_release",
                        state_key=lock_row["state_key"],
                        session_id=session_id,
                        owner=lock_row["owner"],
                    )
                log_event(
                    db,
                    "session_destroy",
                    session_id=session_id,
                    owner=row["owner"] if row else None,
                )
                self._json(200, {"released_locks": len(lock_rows)})
                return
            if path == "/v1/lock/acquire":
                state_key = str(body["key"])
                session_id = str(body["session_id"])
                sess = db.execute(
                    "select * from sessions where session_id=? and active=1",
                    (session_id,),
                ).fetchone()
                if sess is None:
                    self._json(409, {"error": "session_not_active"})
                    return
                held = active_lock(db, state_key)
                if held and held["session_id"] != session_id:
                    self._json(423, {"acquired": False, "holder": held})
                    return
                ts = now()
                if held and held["session_id"] == session_id:
                    self._json(200, {"acquired": True, "lock": held})
                    return
                current = db.execute(
                    "select coalesce(max(lock_index), 0) + 1 from locks"
                ).fetchone()[0]
                db.execute(
                    "insert or replace into locks values(?,?,?,?,?,?,?)",
                    (
                        state_key,
                        session_id,
                        sess["owner"],
                        ts,
                        ts,
                        ts + int(sess["ttl_seconds"]),
                        int(current),
                    ),
                )
                log_event(
                    db,
                    "lock_acquire",
                    state_key=state_key,
                    session_id=session_id,
                    owner=sess["owner"],
                    detail={"lock_index": int(current)},
                )
                self._json(200, {"acquired": True, "lock": active_lock(db, state_key)})
                return
            if path == "/v1/lock/release":
                state_key = str(body["key"])
                session_id = str(body["session_id"])
                row = db.execute(
                    "select * from locks where state_key=? and session_id=?",
                    (state_key, session_id),
                ).fetchone()
                if row:
                    db.execute(
                        "delete from locks where state_key=? and session_id=?",
                        (state_key, session_id),
                    )
                    log_event(
                        db,
                        "lock_release",
                        state_key=state_key,
                        session_id=session_id,
                        owner=row["owner"],
                    )
                self._json(200, {"released": bool(row)})
                return
            if path == "/v1/state/seed":
                state_key = str(body["key"])
                lineage = str(body["lineage"])
                serial = int(body.get("serial", 1))
                state = body["state"]
                db.execute(
                    "insert or replace into states values(?,?,?,?,?,?)",
                    (
                        state_key,
                        lineage,
                        serial,
                        json.dumps(state, sort_keys=True),
                        "fixture_seed",
                        now(),
                    ),
                )
                log_event(
                    db,
                    "state_seed",
                    state_key=state_key,
                    owner="fixture_seed",
                    detail={"serial": serial, "lineage": lineage},
                )
                self._json(200, {"seeded": True, "serial": serial, "lineage": lineage})
                return
            if path == "/v1/state/commit":
                state_key = str(body["key"])
                session_id = str(body["session_id"])
                actor = str(body.get("actor") or "unknown")
                held = active_lock(db, state_key)
                if not held or held["session_id"] != session_id:
                    self._json(409, {"error": "lock_required", "holder": held})
                    return
                row = db.execute(
                    "select * from states where state_key=?", (state_key,)
                ).fetchone()
                if row is None:
                    self._json(404, {"error": "state_not_found"})
                    return
                current = json.loads(row["state_json"])
                new_serial = int(row["serial"]) + 1
                new_state = body["state"]
                new_state["serial"] = new_serial
                new_state["lineage"] = row["lineage"]
                db.execute(
                    "update states set serial=?, state_json=?, updated_by=?, updated_at=? where state_key=?",
                    (
                        new_serial,
                        json.dumps(new_state, sort_keys=True),
                        actor,
                        now(),
                        state_key,
                    ),
                )
                log_event(
                    db,
                    "state_commit",
                    state_key=state_key,
                    session_id=session_id,
                    owner=held["owner"],
                    detail={"serial": new_serial, "actor": actor},
                )
                self._json(
                    200,
                    {
                        "committed": True,
                        "serial": new_serial,
                        "lineage": row["lineage"],
                        "updated_by": actor,
                    },
                )
                return
        self._json(404, {"error": "not_found"})


class ReusableThreadingHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=18500)
    parser.add_argument("--ttl", type=int, default=10)
    args = parser.parse_args()
    init_db(args.db)
    server = ReusableThreadingHTTPServer((args.host, args.port), Handler)
    server.db_path = args.db
    server.default_ttl = args.ttl
    server.serve_forever()


if __name__ == "__main__":
    main()
