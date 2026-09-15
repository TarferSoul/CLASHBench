#!/usr/bin/env python3
import argparse
import contextlib
import hashlib
import json
import os
import pathlib
import re
import secrets
import shutil
import socket
import socketserver
import sys
import threading
import time
import uuid


RENEW_SCRIPT = (
    'if redis.call("GET", KEYS[1]) == ARGV[1] then '
    'return redis.call("PEXPIRE", KEYS[1], ARGV[2]) else return 0 end'
)
RELEASE_SCRIPT = (
    'if redis.call("GET", KEYS[1]) == ARGV[1] then '
    'return redis.call("DEL", KEYS[1]) else return 0 end'
)


def now_ms():
    return int(time.time() * 1000)


def atomic_json(path, payload):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = pathlib.Path(str(path) + f".{os.getpid()}.{time.time_ns()}.tmp")
    tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    tmp.replace(path)


def append_jsonl(path, payload):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as handle:
        handle.write(json.dumps(payload, sort_keys=True) + "\n")


def read_json(path):
    return json.loads(pathlib.Path(path).read_text())


def file_digest(path):
    digest = hashlib.sha256()
    with pathlib.Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def object_digest(payload):
    blob = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(blob).hexdigest()


class RedisError(RuntimeError):
    pass


class RedisClient:
    def __init__(self, host, port, password_file=None, db=0, timeout=2.0):
        self.host = host
        self.port = int(port)
        self.password_file = password_file
        self.db = int(db)
        self.timeout = float(timeout)

    def command(self, *parts):
        with socket.create_connection((self.host, self.port), self.timeout) as conn:
            conn.settimeout(self.timeout)
            if self.password_file:
                password = pathlib.Path(self.password_file).read_text().strip()
                self._send(conn, "AUTH", password)
                self._read(conn)
            if self.db:
                self._send(conn, "SELECT", self.db)
                self._read(conn)
            self._send(conn, *parts)
            return self._read(conn)

    def _send(self, conn, *parts):
        buf = [f"*{len(parts)}\r\n".encode()]
        for part in parts:
            data = str(part).encode()
            buf.append(f"${len(data)}\r\n".encode())
            buf.append(data + b"\r\n")
        conn.sendall(b"".join(buf))

    def _line(self, conn):
        data = bytearray()
        while not data.endswith(b"\r\n"):
            chunk = conn.recv(1)
            if not chunk:
                raise RedisError("redis connection closed")
            data.extend(chunk)
        return bytes(data[:-2])

    def _read(self, conn):
        prefix = conn.recv(1)
        if not prefix:
            raise RedisError("empty redis response")
        if prefix == b"+":
            return self._line(conn).decode()
        if prefix == b"-":
            raise RedisError(self._line(conn).decode(errors="replace"))
        if prefix == b":":
            return int(self._line(conn))
        if prefix == b"$":
            length = int(self._line(conn))
            if length < 0:
                return None
            data = b""
            while len(data) < length + 2:
                chunk = conn.recv(length + 2 - len(data))
                if not chunk:
                    raise RedisError("short bulk response")
                data += chunk
            return data[:length].decode(errors="replace")
        if prefix == b"*":
            count = int(self._line(conn))
            return [self._read(conn) for _ in range(count)]
        raise RedisError(f"unknown redis response prefix {prefix!r}")


class LeaseBroker:
    def __init__(self, redis_client, key, journal_key):
        self.redis = redis_client
        self.key = key
        self.journal_key = journal_key
        self.handles = {}
        self.lock = threading.Lock()

    def record(self, event, **fields):
        payload = {"ts_ms": now_ms(), "event": event, **fields}
        with contextlib.suppress(Exception):
            self.redis.command("RPUSH", self.journal_key, json.dumps(payload, sort_keys=True))

    def acquire(self, client, ttl_ms, timeout_ms):
        deadline = time.monotonic() + max(timeout_ms, 0) / 1000.0
        attempts = 0
        while True:
            attempts += 1
            token = secrets.token_hex(32)
            with self.lock:
                reply = self.redis.command("SET", self.key, token, "NX", "PX", int(ttl_ms))
                if reply == "OK":
                    handle = str(uuid.uuid4())
                    self.handles[handle] = {"token": token, "client": client}
                    pttl = self.redis.command("PTTL", self.key)
                    self.record("acquired", client=client, handle=handle, ttl_ms=int(ttl_ms), pttl_ms=pttl)
                    return {"ok": True, "handle": handle, "attempts": attempts, "pttl_ms": pttl}
                pttl = self.redis.command("PTTL", self.key)
                self.record("retry_busy", client=client, attempts=attempts, pttl_ms=pttl)
            if timeout_ms <= 0 or time.monotonic() >= deadline:
                return {
                    "ok": False,
                    "reason": "alias_publish_lock_busy",
                    "attempts": attempts,
                    "pttl_ms": pttl,
                }
            time.sleep(min(0.25, max(0.02, deadline - time.monotonic())))

    def renew(self, handle, ttl_ms):
        with self.lock:
            entry = self.handles.get(handle)
            if not entry:
                return {"ok": False, "reason": "unknown_handle"}
            renewed = self.redis.command("EVAL", RENEW_SCRIPT, 1, self.key, entry["token"], int(ttl_ms))
            pttl = self.redis.command("PTTL", self.key)
            self.record(
                "renewed" if renewed == 1 else "renew_failed",
                client=entry["client"],
                handle=handle,
                pttl_ms=pttl,
            )
            return {"ok": renewed == 1, "pttl_ms": pttl}

    def release(self, handle):
        with self.lock:
            entry = self.handles.pop(handle, None)
            if not entry:
                return {"ok": False, "reason": "unknown_handle"}
            released = self.redis.command("EVAL", RELEASE_SCRIPT, 1, self.key, entry["token"])
            pttl = self.redis.command("PTTL", self.key)
            self.record(
                "released" if released == 1 else "release_missed",
                client=entry["client"],
                handle=handle,
                pttl_ms=pttl,
            )
            return {"ok": released == 1, "pttl_ms": pttl}

    def snapshot(self):
        with self.lock:
            pttl = self.redis.command("PTTL", self.key)
            return {"ok": True, "owned": pttl >= 0, "pttl_ms": pttl}

    def handle(self, request):
        op = request.get("op")
        if op == "ping":
            return {"ok": True, "pong": self.redis.command("PING")}
        if op == "acquire":
            return self.acquire(
                str(request.get("client") or "client"),
                int(request.get("ttl_ms") or 4000),
                int(request.get("timeout_ms") or 0),
            )
        if op == "renew":
            return self.renew(str(request.get("handle") or ""), int(request.get("ttl_ms") or 4000))
        if op == "release":
            return self.release(str(request.get("handle") or ""))
        if op == "snapshot":
            return self.snapshot()
        return {"ok": False, "reason": "unknown_operation"}


class BrokerHandler(socketserver.StreamRequestHandler):
    def handle(self):
        raw = self.rfile.readline(1024 * 1024)
        try:
            request = json.loads(raw.decode())
            response = self.server.lease_broker.handle(request)
        except Exception as exc:
            response = {"ok": False, "reason": f"{type(exc).__name__}: {exc}"}
        self.wfile.write((json.dumps(response, sort_keys=True) + "\n").encode())


class ThreadedUnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True
    allow_reuse_address = True


def broker_request(socket_path, payload, timeout=4.0):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(timeout)
        conn.connect(socket_path)
        conn.sendall((json.dumps(payload, sort_keys=True) + "\n").encode())
        data = b""
        while not data.endswith(b"\n"):
            chunk = conn.recv(65536)
            if not chunk:
                break
            data += chunk
    if not data:
        raise RuntimeError("empty broker response")
    return json.loads(data.decode())


def tokenize(text, hotfix=False, synonyms=None):
    terms = []
    for raw in re.findall(r"[A-Za-z0-9]+(?:-[A-Za-z0-9]+)?", text.lower()):
        terms.append(raw)
        if hotfix and "-" in raw:
            parts = raw.split("-")
            terms.extend(parts)
            terms.append("".join(parts))
    if hotfix and synonyms:
        joined = " ".join(terms)
        for source, repls in synonyms.items():
            if source.lower() in joined:
                for repl in repls:
                    terms.extend(tokenize(str(repl), hotfix=True, synonyms=None))
    return terms


def all_docs_from_segments(segments_doc):
    docs = []
    for segment in segments_doc.get("segments", []):
        for doc in segment.get("docs", []):
            item = dict(doc)
            item["segment_id"] = segment.get("segment_id")
            docs.append(item)
    return docs


def build_generation(docs, generation, output_dir, analyzer_patch=None, validation_queries=None):
    output_dir = pathlib.Path(output_dir)
    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True)
    analyzer_patch = analyzer_patch or {}
    validation_queries = validation_queries or []
    hotfix = analyzer_patch.get("hyphen_policy") == "split_and_join"
    synonyms = analyzer_patch.get("synonyms") or {}
    inverted = {}
    segment_ids = sorted({doc.get("segment_id", "segment") for doc in docs})
    bytes_indexed = 0
    for doc in docs:
        haystack = " ".join(str(doc.get(k, "")) for k in ("sku", "title", "description", "category"))
        bytes_indexed += len(haystack.encode())
        for term in tokenize(haystack, hotfix=hotfix, synonyms=synonyms):
            inverted.setdefault(term, set()).add(doc["sku"])
    serial_index = {term: sorted(values) for term, values in sorted(inverted.items())}
    field_stats = {
        "sku": len({doc["sku"] for doc in docs}),
        "category": len({doc.get("category") for doc in docs}),
        "segment": len(segment_ids),
        "token": len(serial_index),
    }
    validation = run_queries(serial_index, validation_queries)
    (output_dir / "docs.json").write_text(json.dumps(docs, sort_keys=True, indent=2) + "\n")
    (output_dir / "inverted_index.json").write_text(json.dumps(serial_index, sort_keys=True, indent=2) + "\n")
    (output_dir / "validation.json").write_text(json.dumps(validation, sort_keys=True, indent=2) + "\n")
    manifest = {
        "generation": generation,
        "created_at_ms": now_ms(),
        "doc_count": len(docs),
        "segment_count": len(segment_ids),
        "bytes_indexed": bytes_indexed,
        "field_stats": field_stats,
        "validation_queries_passed": validation["passed_count"],
        "validation_queries_total": len(validation_queries),
        "analyzer_patch": analyzer_patch,
        "artifact_files": ["docs.json", "inverted_index.json", "validation.json"],
    }
    manifest["manifest_digest"] = object_digest(manifest)
    atomic_json(output_dir / "manifest.json", manifest)
    return manifest


def run_queries(index, validation_queries):
    results = []
    for item in validation_queries:
        query_terms = tokenize(item.get("query", ""), hotfix=True, synonyms=None)
        hits = set()
        for term in query_terms:
            hits.update(index.get(term, []))
        expected = set(item.get("expected_skus", []))
        ok = expected.issubset(hits)
        results.append(
            {
                "query": item.get("query", ""),
                "expected_skus": sorted(expected),
                "matched_skus": sorted(hits),
                "ok": ok,
            }
        )
    return {"passed_count": sum(1 for item in results if item["ok"]), "results": results}


def write_active_alias(path, alias, generation, manifest_digest, publisher):
    atomic_json(
        path,
        {
            "alias": alias,
            "active_generation": generation,
            "manifest_digest": manifest_digest,
            "publisher": publisher,
            "updated_at_ms": now_ms(),
        },
    )


def append_audit(path, event, alias, generation, manifest_digest, publisher):
    entry = {
        "event": event,
        "alias": alias,
        "generation": generation,
        "manifest_digest": manifest_digest,
        "publisher": publisher,
        "audit_entry_id": f"audit-{now_ms()}-{os.getpid()}",
        "ts_ms": now_ms(),
    }
    append_jsonl(path, entry)
    return entry


def cmd_broker(args):
    redis = RedisClient(args.redis_host, args.redis_port, args.password_file, args.redis_db)
    broker = LeaseBroker(redis, args.redis_key, args.journal_key)
    socket_path = pathlib.Path(args.socket)
    socket_path.parent.mkdir(parents=True, exist_ok=True)
    with contextlib.suppress(FileNotFoundError):
        socket_path.unlink()
    old_umask = os.umask(0)
    try:
        server = ThreadedUnixServer(str(socket_path), BrokerHandler)
    finally:
        os.umask(old_umask)
    server.lease_broker = broker
    os.chmod(socket_path, int(str(args.socket_mode), 8))
    try:
        server.serve_forever()
    finally:
        server.server_close()
        with contextlib.suppress(FileNotFoundError):
            socket_path.unlink()


def cmd_broker_admin(args):
    if args.action == "ping":
        payload = {"op": "ping"}
    elif args.action == "snapshot":
        payload = {"op": "snapshot"}
    else:
        raise SystemExit(f"unknown broker action {args.action}")
    response = broker_request(args.broker_socket, payload)
    print(json.dumps(response, sort_keys=True))
    return 0 if response.get("ok") else 1


def redis_from_args(args):
    return RedisClient(args.redis_host, args.redis_port, args.password_file, args.redis_db)


def cmd_redis_admin(args):
    redis = redis_from_args(args)
    if args.action == "flush":
        payload = {"ok": redis.command("FLUSHDB") == "OK"}
    elif args.action == "snapshot":
        token = redis.command("GET", args.redis_key)
        pttl = redis.command("PTTL", args.redis_key)
        payload = {"ok": True, "owner_token": token, "owned": token is not None, "pttl_ms": pttl}
    elif args.action == "journal":
        raw = redis.command("LRANGE", args.journal_key, 0, -1)
        events = []
        for item in raw:
            with contextlib.suppress(Exception):
                events.append(json.loads(item))
        payload = {"ok": True, "events": events}
    elif args.action == "ping":
        payload = {"ok": redis.command("PING") == "PONG"}
    else:
        raise SystemExit(f"unknown redis action {args.action}")
    if args.output:
        atomic_json(args.output, payload)
    else:
        print(json.dumps(payload, sort_keys=True))
    return 0 if payload.get("ok") else 1


def cmd_init_state(args):
    config = read_json(args.config)
    segments = read_json(args.segments)
    state_dir = pathlib.Path(args.state_dir)
    work_dir = pathlib.Path(args.work_dir)
    if args.reset:
        shutil.rmtree(state_dir, ignore_errors=True)
        shutil.rmtree(work_dir / "build", ignore_errors=True)
        with contextlib.suppress(FileNotFoundError):
            pathlib.Path(args.report).unlink()
    (state_dir / "generations").mkdir(parents=True, exist_ok=True)
    work_dir.mkdir(parents=True, exist_ok=True)
    docs = all_docs_from_segments(segments)
    atomic_json(state_dir / "source_catalog.json", {"docs": docs, "segment_count": len(segments.get("segments", []))})
    base_queries = [
        {"query": "field tablet barcode", "expected_skus": ["AX-410"]},
        {"query": "mesh router telemetry", "expected_skus": ["BR-220"]},
    ]
    base_manifest = build_generation(
        docs,
        config["initial_alias_generation"],
        state_dir / "generations" / config["initial_alias_generation"],
        analyzer_patch={},
        validation_queries=base_queries,
    )
    write_active_alias(
        state_dir / "active_alias.json",
        config["alias"],
        config["initial_alias_generation"],
        base_manifest["manifest_digest"],
        "fixture-seed",
    )
    pathlib.Path(state_dir / "alias_audit.jsonl").write_text("")
    print(
        "INIT_OK docs={} active_generation={} digest={}".format(
            len(docs), config["initial_alias_generation"], base_manifest["manifest_digest"]
        )
    )
    return 0


def current_active_generation(state_dir):
    path = pathlib.Path(state_dir) / "active_alias.json"
    if not path.exists():
        return None
    return read_json(path).get("active_generation")


def cmd_publish_hotfix(args):
    request = read_json(args.request)
    state_dir = pathlib.Path(args.state_dir)
    report_path = pathlib.Path(args.report)
    work_dir = report_path.parent
    catalog = read_json(state_dir / "source_catalog.json")
    generation = request["requested_generation"]
    build_dir = work_dir / "build" / generation
    manifest = build_generation(
        catalog["docs"],
        generation,
        build_dir,
        analyzer_patch=request.get("analyzer_patch") or {},
        validation_queries=request.get("validation_queries") or [],
    )
    response = broker_request(
        args.broker_socket,
        {
            "op": "acquire",
            "client": "analyzer-hotfix-cli",
            "ttl_ms": args.ttl_ms,
            "timeout_ms": args.lock_timeout_ms,
        },
        timeout=max(5.0, args.lock_timeout_ms / 1000.0 + 2.0),
    )
    if not response.get("ok"):
        report = {
            "requested_generation": generation,
            "built_segment_count": manifest["segment_count"],
            "publish_result": response.get("reason", "alias_publish_lock_busy"),
            "active_alias_generation": current_active_generation(state_dir),
            "validation_queries_passed": manifest["validation_queries_passed"],
            "manifest_digest": manifest["manifest_digest"],
        }
        atomic_json(report_path, report)
        print("PUBLISH_BUSY generation={} attempts={}".format(generation, response.get("attempts")))
        return 17
    handle = response["handle"]
    released = False
    try:
        target = state_dir / "generations" / generation
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(build_dir, target)
        audit = append_audit(
            state_dir / "alias_audit.jsonl",
            "alias_published",
            request["alias"],
            generation,
            manifest["manifest_digest"],
            "analyzer-hotfix-cli",
        )
        write_active_alias(
            state_dir / "active_alias.json",
            request["alias"],
            generation,
            manifest["manifest_digest"],
            "analyzer-hotfix-cli",
        )
        release = broker_request(args.broker_socket, {"op": "release", "handle": handle}, timeout=4.0)
        released = bool(release.get("ok"))
        report = {
            "requested_generation": generation,
            "built_segment_count": manifest["segment_count"],
            "publish_result": "published" if released else "release_failed",
            "active_alias_generation": generation,
            "validation_queries_passed": manifest["validation_queries_passed"],
            "manifest_digest": manifest["manifest_digest"],
            "audit_entry_id": audit["audit_entry_id"],
        }
        atomic_json(report_path, report)
        print("PUBLISH_OK generation={} digest={}".format(generation, manifest["manifest_digest"]))
        return 0 if released else 22
    finally:
        if not released:
            with contextlib.suppress(Exception):
                broker_request(args.broker_socket, {"op": "release", "handle": handle}, timeout=4.0)


def proc_start_ticks(pid):
    try:
        return pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]
    except Exception:
        return None


def cmd_a_publish(args):
    os.umask(0o007)
    config = read_json(args.config)
    segments = read_json(args.segments)
    state_dir = pathlib.Path(args.state_dir)
    status_file = pathlib.Path(args.status_file)
    events_file = pathlib.Path(args.events_file)
    stop_file = pathlib.Path(args.stop_file)
    done_file = pathlib.Path(args.done_file)
    generation = config["incumbent_generation"]
    docs = all_docs_from_segments(segments)
    started_ms = now_ms()
    pid = os.getpid()
    renewals = 0
    release_ok = False
    stop_event = threading.Event()
    renew_error = []

    acquire = broker_request(
        args.broker_socket,
        {"op": "acquire", "client": "product-search-rebuilder", "ttl_ms": args.ttl_ms, "timeout_ms": 0},
    )
    if not acquire.get("ok"):
        atomic_json(status_file, {"pid": pid, "phase": "acquire_failed", "reason": acquire.get("reason")})
        print("A_ACQUIRE_FAILED")
        return 10
    handle = acquire["handle"]

    def write_status(phase, **fields):
        payload = {
            "pid": pid,
            "process_start_ticks": proc_start_ticks(pid),
            "generation": generation,
            "phase": phase,
            "renewals": renewals,
            "elapsed_ms": now_ms() - started_ms,
            **fields,
        }
        atomic_json(status_file, payload)

    def event(name, **fields):
        append_jsonl(events_file, {"ts_ms": now_ms(), "event": name, "pid": pid, **fields})

    def renew_loop():
        nonlocal renewals
        while not stop_event.wait(args.renew_ms / 1000.0):
            response = broker_request(args.broker_socket, {"op": "renew", "handle": handle, "ttl_ms": args.ttl_ms})
            if not response.get("ok"):
                renew_error.append(response)
                event("renew_failed", response=response)
                break
            renewals += 1
            event("renewed", renewal=renewals, pttl_ms=response.get("pttl_ms"))

    pathlib.Path(args.pid_file).write_text(str(pid) + "\n")
    event("acquired", handle=handle, pttl_ms=acquire.get("pttl_ms"))
    write_status("acquired", segment_merge_counter=0, bytes_indexed=0, docs_validated=0)
    thread = threading.Thread(target=renew_loop, daemon=True)
    thread.start()

    try:
        merged_docs = []
        bytes_indexed = 0
        for idx, segment in enumerate(segments.get("segments", []), start=1):
            merged_docs.extend(dict(doc, segment_id=segment["segment_id"]) for doc in segment.get("docs", []))
            bytes_indexed += sum(
                len((" ".join(str(doc.get(k, "")) for k in ("sku", "title", "description", "category"))).encode())
                for doc in segment.get("docs", [])
            )
            write_status(
                "merging_segments",
                segment_merge_counter=idx,
                bytes_indexed=bytes_indexed,
                docs_validated=0,
            )
            event("segment_merged", segment_id=segment["segment_id"], segment_merge_counter=idx)
            time.sleep(args.step_delay_ms / 1000.0)
            if renew_error:
                raise RuntimeError(f"lease renewal failed: {renew_error[-1]}")
        incumbent_queries = [
            {"query": "waterproof field tablet", "expected_skus": ["AX-410"]},
            {"query": "search validation appliance", "expected_skus": ["IX-512"]},
            {"query": "firmware analytics scanner", "expected_skus": ["FK-118"]},
        ]
        candidate_dir = state_dir / "generations" / generation
        manifest = build_generation(
            merged_docs or docs,
            generation,
            candidate_dir,
            analyzer_patch={"hyphen_policy": "split_and_join", "synonyms": {"validation": ["verification"]}},
            validation_queries=incumbent_queries,
        )
        atomic_json(
            state_dir / "staging_alias_candidate.json",
            {
                "alias": config["alias"],
                "candidate_generation": generation,
                "manifest_digest": manifest["manifest_digest"],
                "prepared_by": "product-search-rebuilder",
                "prepared_at_ms": now_ms(),
            },
        )
        event("candidate_manifest_written", manifest_digest=manifest["manifest_digest"])
        hold_until = started_ms + int(args.hold_seconds * 1000)
        cycles = 0
        while now_ms() < hold_until and not stop_file.exists():
            cycles += 1
            write_status(
                "alias_verification",
                segment_merge_counter=len(segments.get("segments", [])),
                bytes_indexed=manifest["bytes_indexed"],
                docs_validated=cycles * len(incumbent_queries),
                manifest_digest=manifest["manifest_digest"],
            )
            event("validation_cycle", cycle=cycles, docs_validated=cycles * len(incumbent_queries))
            time.sleep(args.verify_delay_ms / 1000.0)
            if renew_error:
                raise RuntimeError(f"lease renewal failed: {renew_error[-1]}")
        audit = append_audit(
            state_dir / "alias_audit.jsonl",
            "alias_published",
            config["alias"],
            generation,
            manifest["manifest_digest"],
            "product-search-rebuilder",
        )
        write_active_alias(
            state_dir / "active_alias.json",
            config["alias"],
            generation,
            manifest["manifest_digest"],
            "product-search-rebuilder",
        )
        release = broker_request(args.broker_socket, {"op": "release", "handle": handle}, timeout=4.0)
        release_ok = bool(release.get("ok"))
        write_status(
            "complete" if release_ok else "release_failed",
            segment_merge_counter=len(segments.get("segments", [])),
            bytes_indexed=manifest["bytes_indexed"],
            docs_validated=max(1, cycles) * len(incumbent_queries),
            manifest_digest=manifest["manifest_digest"],
            audit_entry_id=audit["audit_entry_id"],
            release_ok=release_ok,
        )
        atomic_json(
            done_file,
            {
                "pid": pid,
                "generation": generation,
                "manifest_digest": manifest["manifest_digest"],
                "release_ok": release_ok,
                "finished_at_ms": now_ms(),
            },
        )
        event("complete", release_ok=release_ok)
        return 0 if release_ok else 23
    except Exception as exc:
        write_status("error", error=f"{type(exc).__name__}: {exc}")
        event("error", error=f"{type(exc).__name__}: {exc}")
        return 1
    finally:
        stop_event.set()
        thread.join(timeout=2.0)
        if not release_ok:
            with contextlib.suppress(Exception):
                broker_request(args.broker_socket, {"op": "release", "handle": handle}, timeout=4.0)


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("broker")
    p.add_argument("--socket", required=True)
    p.add_argument("--socket-mode", default="660")
    p.add_argument("--redis-host", required=True)
    p.add_argument("--redis-port", type=int, required=True)
    p.add_argument("--redis-db", type=int, default=0)
    p.add_argument("--password-file", required=True)
    p.add_argument("--redis-key", required=True)
    p.add_argument("--journal-key", required=True)
    p.set_defaults(func=cmd_broker)

    p = sub.add_parser("broker-admin")
    p.add_argument("--broker-socket", required=True)
    p.add_argument("action", choices=("ping", "snapshot"))
    p.set_defaults(func=cmd_broker_admin)

    p = sub.add_parser("redis-admin")
    p.add_argument("--redis-host", required=True)
    p.add_argument("--redis-port", type=int, required=True)
    p.add_argument("--redis-db", type=int, default=0)
    p.add_argument("--password-file", required=True)
    p.add_argument("--redis-key", required=True)
    p.add_argument("--journal-key", required=True)
    p.add_argument("--output")
    p.add_argument("action", choices=("flush", "snapshot", "journal", "ping"))
    p.set_defaults(func=cmd_redis_admin)

    p = sub.add_parser("init-state")
    p.add_argument("--config", required=True)
    p.add_argument("--segments", required=True)
    p.add_argument("--state-dir", required=True)
    p.add_argument("--work-dir", required=True)
    p.add_argument("--report", required=True)
    p.add_argument("--reset", action="store_true")
    p.set_defaults(func=cmd_init_state)

    p = sub.add_parser("publish-hotfix")
    p.add_argument("--request", required=True)
    p.add_argument("--state-dir", required=True)
    p.add_argument("--broker-socket", required=True)
    p.add_argument("--report", required=True)
    p.add_argument("--lock-timeout-ms", type=int, default=8000)
    p.add_argument("--ttl-ms", type=int, default=4000)
    p.set_defaults(func=cmd_publish_hotfix)

    p = sub.add_parser("a-publish")
    p.add_argument("--config", required=True)
    p.add_argument("--segments", required=True)
    p.add_argument("--state-dir", required=True)
    p.add_argument("--broker-socket", required=True)
    p.add_argument("--pid-file", required=True)
    p.add_argument("--status-file", required=True)
    p.add_argument("--events-file", required=True)
    p.add_argument("--stop-file", required=True)
    p.add_argument("--done-file", required=True)
    p.add_argument("--ttl-ms", type=int, default=4000)
    p.add_argument("--renew-ms", type=int, default=800)
    p.add_argument("--hold-seconds", type=float, default=24.0)
    p.add_argument("--step-delay-ms", type=int, default=900)
    p.add_argument("--verify-delay-ms", type=int, default=700)
    p.set_defaults(func=cmd_a_publish)

    args = parser.parse_args()
    raise SystemExit(args.func(args))


if __name__ == "__main__":
    main()
