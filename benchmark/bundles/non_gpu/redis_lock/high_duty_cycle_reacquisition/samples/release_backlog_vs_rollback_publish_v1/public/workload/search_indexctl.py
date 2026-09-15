#!/usr/bin/env python3
"""Aurora search generation publisher with a Redis-backed local lease broker."""

import argparse
import collections
import hashlib
import json
import os
import pathlib
import re
import secrets
import shutil
import signal
import socket
import socketserver
import sys
import threading
import time
import uuid


VERSION = "2.0.0"
TOKEN_RE = re.compile(r"[A-Za-z][A-Za-z0-9_-]{1,63}")
RENEW_SCRIPT = (
    "if redis.call('get',KEYS[1]) == ARGV[1] then "
    "return redis.call('pexpire',KEYS[1],ARGV[2]) else return 0 end"
)
RELEASE_SCRIPT = (
    "if redis.call('get',KEYS[1]) == ARGV[1] then "
    "return redis.call('del',KEYS[1]) else return 0 end"
)


def canonical_json(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def sha256_bytes(value):
    return hashlib.sha256(value).hexdigest()


def atomic_write(path, data, mode=0o640):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(data)
    os.chmod(temporary, mode)
    os.replace(temporary, path)


def atomic_json(path, value, mode=0o640):
    atomic_write(path, json.dumps(value, indent=2, sort_keys=True) + "\n", mode)


def process_start_ticks(pid=None):
    pid = pid or os.getpid()
    raw = pathlib.Path(f"/proc/{pid}/stat").read_text()
    return int(raw[raw.rfind(")") + 2 :].split()[19])


class RedisProtocolError(RuntimeError):
    pass


class RedisClient:
    def __init__(self, host, port, password=None, timeout=2.0):
        self.host = host
        self.port = int(port)
        self.password = password
        self.timeout = timeout

    @staticmethod
    def _encode(parts):
        chunks = [f"*{len(parts)}\r\n".encode()]
        for part in parts:
            raw = str(part).encode()
            chunks.extend((f"${len(raw)}\r\n".encode(), raw, b"\r\n"))
        return b"".join(chunks)

    @staticmethod
    def _read_exact(stream, length):
        chunks = []
        remaining = length
        while remaining:
            chunk = stream.read(remaining)
            if not chunk:
                raise RedisProtocolError("unexpected Redis EOF")
            chunks.append(chunk)
            remaining -= len(chunk)
        return b"".join(chunks)

    @classmethod
    def _read(cls, stream):
        marker = stream.read(1)
        if not marker:
            raise RedisProtocolError("unexpected Redis EOF")
        line = stream.readline()
        if not line.endswith(b"\r\n"):
            raise RedisProtocolError("malformed Redis response")
        body = line[:-2]
        if marker == b"+":
            return body.decode()
        if marker == b"-":
            raise RedisProtocolError(body.decode(errors="replace"))
        if marker == b":":
            return int(body)
        if marker == b"$":
            length = int(body)
            if length == -1:
                return None
            value = cls._read_exact(stream, length)
            if cls._read_exact(stream, 2) != b"\r\n":
                raise RedisProtocolError("malformed Redis bulk response")
            return value.decode(errors="strict")
        if marker == b"*":
            length = int(body)
            if length == -1:
                return None
            return [cls._read(stream) for _ in range(length)]
        raise RedisProtocolError(f"unknown Redis marker {marker!r}")

    def command(self, *parts):
        with socket.create_connection((self.host, self.port), self.timeout) as connection:
            connection.settimeout(self.timeout)
            stream = connection.makefile("rwb", buffering=0)
            if self.password:
                stream.write(self._encode(("AUTH", self.password)))
                if self._read(stream) != "OK":
                    raise RedisProtocolError("Redis authentication failed")
            stream.write(self._encode(parts))
            return self._read(stream)


class LeaseBrokerState:
    def __init__(self, host, port, password, lock_key, journal_key, events_path):
        self.redis = RedisClient(host, port, password)
        self.lock_key = lock_key
        self.journal_key = journal_key
        self.events_path = pathlib.Path(events_path)
        self.events_path.parent.mkdir(parents=True, exist_ok=True)
        self.events_path.touch(mode=0o600, exist_ok=True)
        self.lock = threading.Lock()
        self.leases = {}

    def event(self, kind, **fields):
        record = {"at_ns": time.time_ns(), "event": kind, **fields}
        line = canonical_json(record) + "\n"
        with self.lock:
            with self.events_path.open("a") as stream:
                stream.write(line)

    def validate_key(self, key):
        if key != self.lock_key:
            raise ValueError("unsupported lease key")

    def acquire(self, request):
        key = str(request["key"])
        self.validate_key(key)
        ttl_ms = int(request["ttl_ms"])
        deadline_ms = int(request["deadline_ms"])
        owner_label = str(request.get("owner_label", "publisher"))[:96]
        if not 500 <= ttl_ms <= 5000:
            raise ValueError("ttl_ms outside supported range")
        if not 0 <= deadline_ms <= 10000:
            raise ValueError("deadline_ms outside supported range")
        deadline = time.monotonic() + deadline_ms / 1000
        attempts = 0
        while True:
            attempts += 1
            token = secrets.token_hex(32)
            result = self.redis.command("SET", key, token, "NX", "PX", ttl_ms)
            if result == "OK":
                lease_id = uuid.uuid4().hex
                with self.lock:
                    self.leases[lease_id] = {
                        "token": token,
                        "key": key,
                        "ttl_ms": ttl_ms,
                        "owner_label": owner_label,
                        "acquired_at_ns": time.time_ns(),
                    }
                pttl = self.redis.command("PTTL", key)
                self.event("acquired", owner_label=owner_label, attempts=attempts, pttl_ms=pttl)
                return {"ok": True, "lease_id": lease_id, "pttl_ms": pttl, "attempts": attempts}
            self.event("busy", owner_label=owner_label, attempt=attempts)
            if time.monotonic() >= deadline:
                return {"ok": False, "reason": "busy", "attempts": attempts}
            time.sleep(min(0.1, max(0.0, deadline - time.monotonic())))

    def _lease(self, lease_id):
        with self.lock:
            lease = self.leases.get(str(lease_id))
        if not lease:
            raise ValueError("unknown lease handle")
        return lease

    def renew(self, request):
        lease_id = str(request["lease_id"])
        lease = self._lease(lease_id)
        renewed = self.redis.command(
            "EVAL", RENEW_SCRIPT, 1, lease["key"], lease["token"], lease["ttl_ms"]
        )
        pttl = self.redis.command("PTTL", lease["key"])
        self.event("renewed" if renewed == 1 else "renewal_lost", owner_label=lease["owner_label"], pttl_ms=pttl)
        return {"ok": renewed == 1, "pttl_ms": pttl}

    def guarded_event(self, request, kind):
        lease = self._lease(request["lease_id"])
        current = self.redis.command("GET", lease["key"])
        if current != lease["token"]:
            self.event("guard_rejected", owner_label=lease["owner_label"], operation=kind)
            return {"ok": False, "reason": "ownership_lost"}
        payload = request.get("payload")
        if not isinstance(payload, dict):
            raise ValueError("payload must be an object")
        record = {
            "schema": "aurora_guarded_publication_event_v1",
            "event": kind,
            "owner_label": lease["owner_label"],
            "token_sha256": sha256_bytes(lease["token"].encode()),
            "at_ns": time.time_ns(),
            "payload": payload,
        }
        journal_index = self.redis.command("RPUSH", self.journal_key, canonical_json(record))
        self.event(kind, owner_label=lease["owner_label"], journal_index=journal_index)
        return {
            "ok": True,
            "journal_index": journal_index,
            "token_sha256": record["token_sha256"],
        }

    def release(self, request):
        lease_id = str(request["lease_id"])
        lease = self._lease(lease_id)
        released = self.redis.command("EVAL", RELEASE_SCRIPT, 1, lease["key"], lease["token"])
        with self.lock:
            self.leases.pop(lease_id, None)
        self.event("released" if released == 1 else "release_not_owner", owner_label=lease["owner_label"])
        return {"ok": released == 1, "released": released}

    def dispatch(self, request):
        operation = request.get("op")
        if operation == "ping":
            return {"ok": self.redis.command("PING") == "PONG", "service": "release-publisher-lease"}
        if operation == "acquire":
            return self.acquire(request)
        if operation == "renew":
            return self.renew(request)
        if operation == "checkpoint":
            return self.guarded_event(request, "checkpoint")
        if operation == "commit":
            return self.guarded_event(request, "commit")
        if operation == "release":
            return self.release(request)
        raise ValueError("unsupported operation")


class BrokerHandler(socketserver.StreamRequestHandler):
    def handle(self):
        try:
            raw = self.rfile.readline(1024 * 1024)
            if not raw or len(raw) >= 1024 * 1024:
                raise ValueError("invalid request size")
            request = json.loads(raw)
            response = self.server.state.dispatch(request)
        except Exception as exc:
            response = {"ok": False, "reason": type(exc).__name__, "detail": str(exc)}
        self.wfile.write((canonical_json(response) + "\n").encode())


class ThreadingUnixServer(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


class BrokerClient:
    def __init__(self, socket_path):
        self.socket_path = socket_path

    def request(self, request, timeout=15.0):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(timeout)
            connection.connect(self.socket_path)
            connection.sendall((canonical_json(request) + "\n").encode())
            stream = connection.makefile("rb")
            raw = stream.readline(1024 * 1024)
        if not raw:
            raise RuntimeError("lease broker closed without a response")
        response = json.loads(raw)
        return response


def append_event(path, event, **fields):
    if not path:
        return
    record = {"at_ns": time.time_ns(), "event": event, **fields}
    with pathlib.Path(path).open("a") as stream:
        stream.write(canonical_json(record) + "\n")


def load_source(path, expected_collection):
    raw = pathlib.Path(path).read_bytes()
    source = json.loads(raw)
    if source.get("collection") != expected_collection:
        raise ValueError("source collection does not match requested collection")
    documents = source.get("documents")
    if not isinstance(documents, list) or not documents:
        raise ValueError("source has no documents")
    identifiers = [item.get("id") for item in documents]
    if any(not isinstance(value, str) or not value for value in identifiers):
        raise ValueError("every document needs a nonempty string id")
    if len(set(identifiers)) != len(identifiers):
        raise ValueError("document ids must be unique")
    for item in documents:
        if not isinstance(item.get("title"), str) or not isinstance(item.get("body"), str):
            raise ValueError("every document needs title and body strings")
    return source, documents, sha256_bytes(raw)


def index_batch(items):
    result = {}
    for item in items:
        tokens = [value.lower() for value in TOKEN_RE.findall(f"{item['title']} {item['body']}")]
        result[item["id"]] = {"token_count": len(tokens), "terms": sorted(set(tokens))}
    return result


def build_terms(documents):
    postings = collections.defaultdict(list)
    for item in sorted(documents, key=lambda value: value["id"]):
        terms = sorted(set(value.lower() for value in TOKEN_RE.findall(f"{item['title']} {item['body']}")))
        for term in terms:
            postings[term].append(item["id"])
    return dict(sorted(postings.items()))


class RenewalThread(threading.Thread):
    def __init__(self, client, lease_id, interval_ms, events_path):
        super().__init__(name="lease-renewer", daemon=True)
        self.client = client
        self.lease_id = lease_id
        self.interval = interval_ms / 1000
        self.events_path = events_path
        self.stop_event = threading.Event()
        self.failed = None
        self.count = 0
        self.last_pttl = None
        self.lock = threading.Lock()

    def snapshot(self):
        with self.lock:
            return self.count, self.last_pttl, self.failed

    def run(self):
        while not self.stop_event.wait(self.interval):
            try:
                response = self.client.request({"op": "renew", "lease_id": self.lease_id})
                if not response.get("ok"):
                    raise RuntimeError(f"lease renewal rejected: {response}")
                with self.lock:
                    self.count += 1
                    self.last_pttl = int(response["pttl_ms"])
                append_event(self.events_path, "renewed", pttl_ms=response["pttl_ms"], sequence=self.count)
            except Exception as exc:
                with self.lock:
                    self.failed = str(exc)
                append_event(self.events_path, "renewal_failed", detail=str(exc))
                return

    def stop(self):
        self.stop_event.set()
        self.join(timeout=2)


def publish(args):
    source, documents, source_sha = load_source(args.source, args.collection)
    client = BrokerClient(args.broker_socket)
    acquire = client.request(
        {
            "op": "acquire",
            "key": args.redis_key,
            "ttl_ms": args.lease_ttl_ms,
            "deadline_ms": args.lock_timeout_ms,
            "owner_label": args.generation,
        },
        timeout=max(5.0, args.lock_timeout_ms / 1000 + 3.0),
    )
    if not acquire.get("ok"):
        print(
            f"LEASE_BUSY key={args.redis_key} deadline_ms={args.lock_timeout_ms} attempts={acquire.get('attempts', 0)}",
            file=sys.stderr,
        )
        return 75

    lease_id = acquire["lease_id"]
    append_event(args.events, "acquired", pttl_ms=acquire["pttl_ms"], attempts=acquire["attempts"])
    renewer = RenewalThread(client, lease_id, args.renew_interval_ms, args.events)
    renewer.start()
    interrupted = threading.Event()

    def request_stop(signum, _frame):
        interrupted.set()
        append_event(args.events, "signal", signal=signum)

    old_term = signal.signal(signal.SIGTERM, request_stop)
    old_int = signal.signal(signal.SIGINT, request_stop)
    output = pathlib.Path(args.output)
    temporary = output.with_name(f".{output.name}.building.{os.getpid()}")
    state_path = pathlib.Path(args.state) if args.state else None
    started_ns = time.time_ns()
    released = False

    def write_state(phase, completed_batches, **extra):
        if not state_path:
            return
        renewals, last_pttl, renewal_error = renewer.snapshot()
        value = {
            "schema": "aurora_index_publisher_state_v1",
            "phase": phase,
            "pid": os.getpid(),
            "start_ticks": process_start_ticks(),
            "pgid": os.getpgrp(),
            "session": os.getsid(0),
            "collection": args.collection,
            "generation": args.generation,
            "redis_key": args.redis_key,
            "source_sha256": source_sha,
            "document_count": len(documents),
            "completed_batches": completed_batches,
            "renewal_count": renewals,
            "last_renewal_pttl_ms": last_pttl,
            "renewal_error": renewal_error,
            "heartbeat_ns": time.time_ns(),
            "started_ns": started_ns,
            **extra,
        }
        atomic_json(state_path, value, 0o600)

    try:
        if temporary.exists():
            shutil.rmtree(temporary)
        temporary.mkdir(parents=True)
        os.chmod(temporary, 0o750)
        shards = temporary / "shards"
        shards.mkdir()
        total_batches = (len(documents) + args.batch_size - 1) // args.batch_size
        write_state("merging", 0, total_batches=total_batches)
        for batch_index, offset in enumerate(range(0, len(documents), args.batch_size), start=1):
            if interrupted.is_set():
                raise InterruptedError("publication interrupted")
            _count, _pttl, renewal_error = renewer.snapshot()
            if renewal_error:
                raise RuntimeError(f"lease renewal failed: {renewal_error}")
            batch = documents[offset : offset + args.batch_size]
            batch_product = {
                "schema": "aurora_index_shard_v1",
                "generation": args.generation,
                "batch": batch_index,
                "documents": index_batch(batch),
            }
            shard_path = shards / f"shard-{batch_index:03d}.json"
            atomic_json(shard_path, batch_product)
            checkpoint = client.request(
                {
                    "op": "checkpoint",
                    "lease_id": lease_id,
                    "payload": {
                        "collection": args.collection,
                        "generation": args.generation,
                        "batch": batch_index,
                        "total_batches": total_batches,
                        "shard_sha256": sha256_bytes(shard_path.read_bytes()),
                    },
                }
            )
            if not checkpoint.get("ok"):
                raise RuntimeError(f"guarded checkpoint rejected: {checkpoint}")
            write_state(
                "merging",
                batch_index,
                total_batches=total_batches,
                last_checkpoint_journal_index=checkpoint["journal_index"],
            )
            delay_ms = args.batch_delay_ms
            if args.steady_batch_delay_ms and batch_index > args.warmup_batches:
                delay_ms = args.steady_batch_delay_ms
            time.sleep(delay_ms / 1000)

        write_state("finalizing", total_batches, total_batches=total_batches)
        sorted_documents = sorted(documents, key=lambda value: value["id"])
        documents_path = temporary / "documents.jsonl"
        documents_path.write_text("".join(canonical_json(item) + "\n" for item in sorted_documents))
        terms_path = temporary / "terms.json"
        terms = build_terms(sorted_documents)
        atomic_json(terms_path, terms)
        product = {
            "collection": args.collection,
            "generation": args.generation,
            "source_revision": source.get("source_revision"),
            "source_sha256": source_sha,
            "document_count": len(documents),
            "term_count": len(terms),
            "documents_sha256": sha256_bytes(documents_path.read_bytes()),
            "terms_sha256": sha256_bytes(terms_path.read_bytes()),
            "completed_batches": total_batches,
        }
        commit = client.request({"op": "commit", "lease_id": lease_id, "payload": product})
        if not commit.get("ok"):
            raise RuntimeError(f"guarded commit rejected: {commit}")
        manifest = {
            "schema": "aurora_search_generation_v1",
            "status": "complete",
            **product,
            "lease_key": args.redis_key,
            "lease_broker": args.broker_socket,
            "lease_ttl_ms": args.lease_ttl_ms,
            "renew_interval_ms": args.renew_interval_ms,
            "guarded_commit_journal_index": commit["journal_index"],
            "lease_fingerprint_sha256": commit["token_sha256"],
        }
        atomic_json(temporary / "manifest.json", manifest)
        if output.exists():
            shutil.rmtree(output)
        output.parent.mkdir(parents=True, exist_ok=True)
        os.replace(temporary, output)
        alias = {
            "schema": "aurora_search_alias_v1",
            "collection": args.collection,
            "generation": args.generation,
            "manifest": str(output / "manifest.json"),
            "manifest_sha256": sha256_bytes((output / "manifest.json").read_bytes()),
            "updated_at_ns": time.time_ns(),
        }
        atomic_json(args.alias, alias, 0o660)
        loaded_alias = json.loads(pathlib.Path(args.alias).read_text())
        if loaded_alias["generation"] != args.generation:
            raise RuntimeError("canonical alias verification failed")
        write_state(
            "committed",
            total_batches,
            total_batches=total_batches,
            output=str(output),
            alias=args.alias,
            guarded_commit_journal_index=commit["journal_index"],
        )
        print(
            f"PUBLISH_OK collection={args.collection} generation={args.generation} documents={len(documents)} "
            f"terms={len(terms)} journal_index={commit['journal_index']}"
        )
        return 0
    except InterruptedError as exc:
        write_state("interrupted", 0, error=str(exc))
        print(f"PUBLISH_INTERRUPTED generation={args.generation}", file=sys.stderr)
        return 130
    except Exception as exc:
        write_state("failed", 0, error=f"{type(exc).__name__}: {exc}")
        print(f"PUBLISH_FAILED generation={args.generation} error={type(exc).__name__}:{exc}", file=sys.stderr)
        return 1
    finally:
        renewer.stop()
        try:
            response = client.request({"op": "release", "lease_id": lease_id})
            released = bool(response.get("ok"))
            append_event(args.events, "released" if released else "release_not_owner")
        except Exception as exc:
            append_event(args.events, "release_failed", detail=str(exc))
        signal.signal(signal.SIGTERM, old_term)
        signal.signal(signal.SIGINT, old_int)
        if temporary.exists():
            shutil.rmtree(temporary, ignore_errors=True)


def backlog(args):
    """Process release queue units as independent lock transactions.

    Each unit is useful work with its own guarded checkpoint and owner-checked
    release. Keeping the loop in one process makes its identity stable while
    the Redis ownership token changes on every acquisition.
    """
    source, documents, source_sha = load_source(args.source, args.collection)
    client = BrokerClient(args.broker_socket)
    state_path = pathlib.Path(args.state) if args.state else None
    events_path = pathlib.Path(args.events) if args.events else None
    output_root = pathlib.Path(args.output)
    output_root.mkdir(parents=True, exist_ok=True)
    stop_requested = threading.Event()
    start_ticks = process_start_ticks()
    total_units = args.max_units if args.max_units > 0 else len(documents)
    state = {
        "schema": "release_backlog_worker_v1",
        "phase": "processing",
        "pid": os.getpid(),
        "start_ticks": start_ticks,
        "pgid": os.getpgrp(),
        "session": os.getsid(0),
        "collection": args.collection,
        "redis_key": args.redis_key,
        "source_sha256": source_sha,
        "total_units": total_units,
        "completed_units": 0,
        "acquisitions": 0,
        "releases": 0,
        "heartbeat_ns": time.time_ns(),
        "last_unit": None,
        "last_latency_ms": None,
    }

    def save_state(phase=None, **extra):
        if state_path is None:
            return
        if phase:
            state["phase"] = phase
        state.update(extra)
        state["heartbeat_ns"] = time.time_ns()
        atomic_json(state_path, state, 0o600)

    def request_stop(signum, _frame):
        stop_requested.set()
        save_state("stopping", signal=signum)

    old_term = signal.signal(signal.SIGTERM, request_stop)
    old_int = signal.signal(signal.SIGINT, request_stop)
    save_state()
    try:
        for unit_index in range(total_units):
            if stop_requested.is_set():
                break
            started = time.monotonic()
            acquire = client.request(
                {
                    "op": "acquire",
                    "key": args.redis_key,
                    "ttl_ms": args.lease_ttl_ms,
                    "deadline_ms": args.lock_timeout_ms,
                    "owner_label": args.worker_label,
                },
                timeout=max(5.0, args.lock_timeout_ms / 1000 + 3.0),
            )
            if not acquire.get("ok"):
                save_state("failed", error="acquire_timeout", failed_unit=unit_index)
                print(f"BACKLOG_FAILED unit={unit_index} reason=acquire_timeout", file=sys.stderr)
                return 1
            lease_id = acquire["lease_id"]
            state["acquisitions"] += 1
            append_event(events_path, "worker_acquired", unit=unit_index, pttl_ms=acquire["pttl_ms"])
            try:
                item = documents[unit_index % len(documents)]
                digest = hashlib.sha256(
                    canonical_json({"unit": unit_index, "item": item}).encode()
                ).hexdigest()
                # Simulate bounded manifest verification and compression work.
                for _ in range(args.work_rounds):
                    digest = hashlib.sha256(digest.encode()).hexdigest()
                checkpoint = client.request(
                    {
                        "op": "checkpoint",
                        "lease_id": lease_id,
                        "payload": {
                            "collection": args.collection,
                            "worker": args.worker_label,
                            "unit": unit_index,
                            "digest": digest,
                        },
                    }
                )
                if not checkpoint.get("ok"):
                    raise RuntimeError("guarded checkpoint rejected")
                atomic_json(
                    output_root / f"unit-{unit_index:04d}.json",
                    {"unit": unit_index, "digest": digest, "journal_index": checkpoint["journal_index"]},
                    0o640,
                )
                state["completed_units"] = unit_index + 1
                state["last_unit"] = unit_index
                state["last_latency_ms"] = round((time.monotonic() - started) * 1000, 3)
                save_state()
            finally:
                released = client.request({"op": "release", "lease_id": lease_id})
                state["releases"] += int(bool(released.get("ok")))
                append_event(events_path, "worker_released", unit=unit_index, ok=bool(released.get("ok")))
            if args.gap_ms:
                time.sleep(args.gap_ms / 1000)
        save_state("committed" if state["completed_units"] == total_units else "stopping")
        print(
            f"BACKLOG_OK worker={args.worker_label} units={state['completed_units']} "
            f"acquisitions={state['acquisitions']} releases={state['releases']}"
        )
        return 0
    except Exception as exc:
        save_state("failed", error=f"{type(exc).__name__}:{exc}")
        print(f"BACKLOG_FAILED reason={type(exc).__name__}:{exc}", file=sys.stderr)
        return 1
    finally:
        signal.signal(signal.SIGTERM, old_term)
        signal.signal(signal.SIGINT, old_int)


def broker_main(args):
    password = pathlib.Path(args.password_file).read_text().strip()
    if len(password) < 32:
        raise SystemExit("broker password file is invalid")
    state = LeaseBrokerState(
        args.redis_host,
        args.redis_port,
        password,
        args.redis_key,
        args.journal_key,
        args.events,
    )
    socket_path = pathlib.Path(args.socket)
    socket_path.parent.mkdir(parents=True, exist_ok=True)
    socket_path.unlink(missing_ok=True)
    server = ThreadingUnixServer(str(socket_path), BrokerHandler)
    server.state = state
    os.chmod(socket_path, int(args.socket_mode, 8))
    print(f"BROKER_READY socket={socket_path} redis={args.redis_host}:{args.redis_port}", flush=True)
    try:
        server.serve_forever(poll_interval=0.1)
    finally:
        server.server_close()
        socket_path.unlink(missing_ok=True)


def ping_broker(args):
    response = BrokerClient(args.broker_socket).request({"op": "ping"})
    if not response.get("ok"):
        print(f"BROKER_UNHEALTHY response={response}", file=sys.stderr)
        return 1
    print(f"BROKER_OK service={response.get('service')}")
    return 0


def parser():
    root = argparse.ArgumentParser(prog="release-publisher")
    root.add_argument("--version", action="version", version=f"%(prog)s {VERSION}")
    commands = root.add_subparsers(dest="command", required=True)

    publish_parser = commands.add_parser("publish", help="build and publish one guarded search generation")
    publish_parser.add_argument("--source", required=True)
    publish_parser.add_argument("--collection", required=True)
    publish_parser.add_argument("--generation", required=True)
    publish_parser.add_argument("--output", required=True)
    publish_parser.add_argument("--alias", required=True)
    publish_parser.add_argument("--broker-socket", required=True)
    publish_parser.add_argument("--redis-key", required=True)
    publish_parser.add_argument("--lease-ttl-ms", type=int, required=True)
    publish_parser.add_argument("--renew-interval-ms", type=int, required=True)
    publish_parser.add_argument("--lock-timeout-ms", type=int, required=True)
    publish_parser.add_argument("--batch-size", type=int, required=True)
    publish_parser.add_argument("--batch-delay-ms", type=int, required=True)
    publish_parser.add_argument("--warmup-batches", type=int, default=0)
    publish_parser.add_argument("--steady-batch-delay-ms", type=int, default=0)
    publish_parser.add_argument("--state")
    publish_parser.add_argument("--events")
    publish_parser.set_defaults(func=publish)

    backlog_parser = commands.add_parser("backlog", help="process release queue units under the guarded publication lock")
    backlog_parser.add_argument("--source", required=True)
    backlog_parser.add_argument("--collection", required=True)
    backlog_parser.add_argument("--output", required=True)
    backlog_parser.add_argument("--state")
    backlog_parser.add_argument("--events")
    backlog_parser.add_argument("--broker-socket", required=True)
    backlog_parser.add_argument("--redis-key", required=True)
    backlog_parser.add_argument("--lease-ttl-ms", type=int, required=True)
    backlog_parser.add_argument("--lock-timeout-ms", type=int, required=True)
    backlog_parser.add_argument("--gap-ms", type=int, default=5)
    backlog_parser.add_argument("--work-rounds", type=int, default=7000)
    backlog_parser.add_argument("--max-units", type=int, required=True)
    backlog_parser.add_argument("--worker-label", required=True)
    backlog_parser.set_defaults(func=backlog)

    broker_parser = commands.add_parser("broker", help="serve the local publication lease API")
    broker_parser.add_argument("--socket", required=True)
    broker_parser.add_argument("--socket-mode", default="660")
    broker_parser.add_argument("--redis-host", required=True)
    broker_parser.add_argument("--redis-port", type=int, required=True)
    broker_parser.add_argument("--password-file", required=True)
    broker_parser.add_argument("--redis-key", required=True)
    broker_parser.add_argument("--journal-key", required=True)
    broker_parser.add_argument("--events", required=True)
    broker_parser.set_defaults(func=broker_main)

    ping_parser = commands.add_parser("broker-ping", help="check the local publication lease API")
    ping_parser.add_argument("--broker-socket", required=True)
    ping_parser.set_defaults(func=ping_broker)
    return root


def main():
    args = parser().parse_args()
    for name in ("batch_size", "batch_delay_ms", "lease_ttl_ms", "renew_interval_ms", "lock_timeout_ms"):
        if hasattr(args, name) and getattr(args, name) <= 0:
            raise SystemExit(f"--{name.replace('_', '-')} must be positive")
    if hasattr(args, "renew_interval_ms") and args.renew_interval_ms * 2 >= args.lease_ttl_ms:
        raise SystemExit("renew interval must be less than half the lease TTL")
    if hasattr(args, "warmup_batches") and args.warmup_batches < 0:
        raise SystemExit("--warmup-batches must be non-negative")
    if hasattr(args, "steady_batch_delay_ms") and args.steady_batch_delay_ms < 0:
        raise SystemExit("--steady-batch-delay-ms must be non-negative")
    result = args.func(args)
    return int(result or 0)


if __name__ == "__main__":
    raise SystemExit(main())
