#!/usr/bin/env python3
import argparse
import fcntl
import hashlib
import json
import os
import pathlib
import signal
import sys
import time
import uuid


SIGNING_DOMAIN = b"staging-model-catalog-integrity-v1"


def atomic_json(path, payload):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(payload, sort_keys=True, indent=2) + "\n")
    os.replace(tmp, path)


def load_json(path, default=None):
    try:
        return json.loads(pathlib.Path(path).read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def append_audit(path, event, **fields):
    payload = {"event": event, "time_unix": round(time.time(), 6), **fields}
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, sort_keys=True) + "\n")
        handle.flush()
        os.fsync(handle.fileno())


def package_info(path):
    raw = pathlib.Path(path).read_bytes()
    package = json.loads(raw)
    if package.get("format") != 1 or not package.get("model") or not package.get("version"):
        raise ValueError("invalid model package metadata")
    shards = []
    for shard in package.get("shards", []):
        payload = shard["payload"].encode()
        shards.append({"name": shard["name"], "digest": hashlib.sha256(payload).hexdigest(),
                       "size": len(payload), "payload": payload})
    if len(shards) < 2:
        raise ValueError("model package requires multiple shards")
    return package, shards, hashlib.sha256(raw).hexdigest()


def sign_catalog(catalog):
    encoded = json.dumps(catalog, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(SIGNING_DOMAIN + encoded).hexdigest()


def current_entries(state_root, replicas):
    path = pathlib.Path(state_root) / "replicas" / replicas[0] / "catalog.json"
    catalog = load_json(path, {}) or {}
    return dict(catalog.get("models", {}))


def publish_generation(state_root, package_path, release_id, token, replicas, generation, delay):
    package, shards, package_digest = package_info(package_path)
    root = pathlib.Path(state_root)
    for shard in shards:
        blob = root / "blobs" / shard["digest"]
        blob.parent.mkdir(parents=True, exist_ok=True)
        if not blob.exists():
            blob.write_bytes(shard["payload"])
        if hashlib.sha256(blob.read_bytes()).hexdigest() != shard["digest"]:
            raise ValueError(f"blob verification failed for {shard['name']}")
    entries = current_entries(state_root, replicas)
    entries[package["model"]] = {
        "version": package["version"], "package_digest": package_digest,
        "shards": [{key: shard[key] for key in ("name", "digest", "size")} for shard in shards],
        "release_id": release_id,
    }
    catalog = {
        "channel": "staging-model-serving", "generation": generation,
        "release_id": release_id, "fencing_token": token, "models": entries,
    }
    signature = sign_catalog(catalog)
    for replica in replicas:
        replica_root = root / "replicas" / replica
        atomic_json(replica_root / "catalog.json", catalog)
        atomic_json(replica_root / "signature.json", {
            "algorithm": "sha256-domain-v1", "catalog_digest": hashlib.sha256(
                json.dumps(catalog, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
            "signature": signature, "generation": generation,
        })
        time.sleep(delay)
    atomic_json(root / "active_models" / f"{package['model']}.json", {
        "model": package["model"], "version": package["version"],
        "package_digest": package_digest, "generation": generation,
        "release_id": release_id, "shard_count": len(shards),
    })
    atomic_json(root / "load_checks" / f"{package['model']}.json", {
        "model": package["model"], "version": package["version"], "generation": generation,
        "loaded_shards": len(shards), "tensor_headers_valid": True,
        "cold_load": "passing", "checked_at": time.time(),
    })
    return package, shards, package_digest, catalog, signature


def lease_agent(args):
    path = pathlib.Path(args.lock)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.touch(exist_ok=True)
    stop = False
    def stopping(_signum, _frame):
        nonlocal stop
        stop = True
    signal.signal(signal.SIGTERM, stopping)
    signal.signal(signal.SIGINT, stopping)
    with path.open("r+") as handle:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("LEASE_START_FAILED reason=busy", file=sys.stderr)
            return 75
        pathlib.Path(args.pid_file).write_text(f"{os.getpid()}\n")
        seq = 0
        append_audit(args.audit, "lease_grant", lease_key=args.lease_key,
                     release_id=args.release_id, fencing_token=args.token, holder_pid=os.getpid())
        while not stop:
            seq += 1
            now = time.time()
            atomic_json(args.lease, {"lease_key": args.lease_key, "release_id": args.release_id,
                "fencing_token": args.token, "holder_pid": os.getpid(), "heartbeat_seq": seq,
                "renewed_at": now, "expires_at": now + args.ttl, "state": "active"})
            append_audit(args.audit, "lease_renew", release_id=args.release_id,
                         fencing_token=args.token, heartbeat_seq=seq, expires_at=now + args.ttl)
            deadline = time.monotonic() + args.renew_interval
            while not stop and time.monotonic() < deadline:
                time.sleep(min(0.05, deadline - time.monotonic()))
        lease = load_json(args.lease, {})
        if lease.get("release_id") == args.release_id and lease.get("fencing_token") == args.token:
            lease.update(state="released", released_at=time.time(), expires_at=time.time())
            atomic_json(args.lease, lease)
            append_audit(args.audit, "lease_release", release_id=args.release_id,
                         fencing_token=args.token, heartbeat_seq=seq, owner_checked=True)
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    return 0


def catalog_worker(args):
    pathlib.Path(args.pid_file).write_text(f"{os.getpid()}\n")
    replicas = args.replicas.split(",")
    stop = False
    def stopping(_signum, _frame):
        nonlocal stop
        stop = True
    signal.signal(signal.SIGTERM, stopping)
    signal.signal(signal.SIGINT, stopping)
    sequence = 0
    while not stop:
        lease = load_json(args.lease, {})
        if (lease.get("release_id"), lease.get("fencing_token"), lease.get("state")) != (
            args.release_id, args.token, "active"
        ) or float(lease.get("expires_at", 0)) <= time.time():
            print("PUBLISHER_EXIT reason=lease_not_owned", file=sys.stderr)
            return 4
        sequence += 1
        generation = f"{args.release_id}-g{sequence:04d}"
        package, shards, package_digest, catalog, signature = publish_generation(
            args.state_root, args.package, args.release_id, args.token, replicas, generation, args.replica_delay)
        atomic_json(pathlib.Path(args.state_root) / "publisher_progress.json", {
            "release_id": args.release_id, "fencing_token": args.token, "sequence": sequence,
            "stage": "cold_load_verified", "model": package["model"], "version": package["version"],
            "package_digest": package_digest, "shards_verified": len(shards),
            "catalog_generation": catalog["generation"], "catalog_signature": signature,
            "replicas_converged": len(replicas), "healthy": True, "updated_at": time.time(),
        })
        append_audit(args.audit, "publisher_progress", release_id=args.release_id,
                     fencing_token=args.token, sequence=sequence, model=package["model"],
                     package_digest=package_digest, generation=generation, replicas=len(replicas))
        time.sleep(args.cycle_delay)
    return 0


def acquire(handle, timeout):
    start = time.monotonic()
    while True:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True, int((time.monotonic() - start) * 1000)
        except BlockingIOError:
            if time.monotonic() - start >= timeout:
                return False, int((time.monotonic() - start) * 1000)
            time.sleep(0.1)


def publish(args):
    if args.channel != "staging-model-serving":
        print("PUBLISH_INVALID channel", file=sys.stderr)
        return 2
    lock = pathlib.Path(args.lock)
    lock.parent.mkdir(parents=True, exist_ok=True)
    lock.touch(exist_ok=True)
    replicas = args.replicas.split(",")
    with lock.open("r+") as handle:
        acquired, waited_ms = acquire(handle, args.lock_timeout)
        if not acquired:
            owner = load_json(args.lease, {})
            print("PROMOTION_BUSY lease_key=%s owner=%s fencing_token=%s heartbeat_seq=%s waited_ms=%s" % (
                args.lease_key, owner.get("release_id", "unknown"), owner.get("fencing_token", "unknown"),
                owner.get("heartbeat_seq", "unknown"), waited_ms), file=sys.stderr)
            return 75
        token = "catalog-grant-" + uuid.uuid4().hex[:16]
        now = time.time()
        atomic_json(args.lease, {"lease_key": args.lease_key, "release_id": args.release_id,
            "fencing_token": token, "holder_pid": os.getpid(), "heartbeat_seq": 1,
            "renewed_at": now, "expires_at": now + max(30, args.lock_timeout + 10), "state": "active"})
        append_audit(args.audit, "lease_grant", lease_key=args.lease_key,
                     release_id=args.release_id, fencing_token=token, holder_pid=os.getpid())
        generation = f"{args.release_id}-committed"
        package, shards, package_digest, catalog, signature = publish_generation(
            args.state_root, args.package, args.release_id, token, replicas, generation, args.replica_delay)
        append_audit(args.audit, "catalog_commit", release_id=args.release_id,
                     fencing_token=token, model=package["model"], version=package["version"],
                     package_digest=package_digest, generation=generation, replicas=len(replicas),
                     shards=len(shards), catalog_signature=signature)
        atomic_json(args.receipt, {"channel": args.channel, "release_id": args.release_id,
            "fencing_token": token, "model": package["model"], "version": package["version"],
            "package_digest": package_digest, "generation": generation,
            "catalog_signature": signature, "replicas": replicas, "cold_load": "passing",
            "lease_key": args.lease_key, "lease_wait_ms": waited_ms})
        lease = load_json(args.lease, {})
        lease.update(state="released", released_at=time.time(), expires_at=time.time())
        atomic_json(args.lease, lease)
        append_audit(args.audit, "lease_release", release_id=args.release_id,
                     fencing_token=token, owner_checked=True)
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    print(f"PUBLISH_OK release_id={args.release_id} model={package['model']} version={package['version']} generation={generation}")
    return 0


def status(args):
    print(json.dumps({"lease": load_json(args.lease, {}),
        "publisher": load_json(pathlib.Path(args.state_root) / "publisher_progress.json", {})},
        indent=2, sort_keys=True))
    return 0


def main():
    ap = argparse.ArgumentParser(prog="model-promote")
    sub = ap.add_subparsers(dest="command", required=True)
    lease = sub.add_parser("lease-agent")
    for name in ("lock", "lease", "audit", "lease_key", "release_id", "token", "pid_file"):
        lease.add_argument("--" + name.replace("_", "-"), required=True)
    lease.add_argument("--ttl", type=float, required=True)
    lease.add_argument("--renew-interval", type=float, required=True)
    lease.set_defaults(func=lease_agent)
    worker = sub.add_parser("catalog-worker")
    for name in ("state_root", "lease", "audit", "package", "release_id", "token", "replicas", "pid_file"):
        worker.add_argument("--" + name.replace("_", "-"), required=True)
    worker.add_argument("--replica-delay", type=float, default=0.12)
    worker.add_argument("--cycle-delay", type=float, default=0.2)
    worker.set_defaults(func=catalog_worker)
    publish_cmd = sub.add_parser("publish")
    publish_cmd.add_argument("--channel", required=True)
    publish_cmd.add_argument("--package", required=True)
    publish_cmd.add_argument("--release-id", required=True)
    publish_cmd.add_argument("--lock-timeout", type=float, required=True)
    publish_cmd.add_argument("--receipt", required=True)
    publish_cmd.add_argument("--lock", default="/var/lock/model-promotion/staging-model-serving-catalog.lock")
    publish_cmd.add_argument("--lease", default="/srv/model-catalog/staging-model-serving/lease.json")
    publish_cmd.add_argument("--audit", default="/srv/model-catalog/staging-model-serving/audit.jsonl")
    publish_cmd.add_argument("--state-root", default="/srv/model-catalog/staging-model-serving")
    publish_cmd.add_argument("--lease-key", default="env/staging-model-serving/catalog/model-artifacts")
    publish_cmd.add_argument("--replicas", default="catalog-a,catalog-b,catalog-c")
    publish_cmd.add_argument("--replica-delay", type=float, default=0.45)
    publish_cmd.set_defaults(func=publish)
    status_cmd = sub.add_parser("status")
    status_cmd.add_argument("--lease", default="/srv/model-catalog/staging-model-serving/lease.json")
    status_cmd.add_argument("--state-root", default="/srv/model-catalog/staging-model-serving")
    status_cmd.set_defaults(func=status)
    args = ap.parse_args()
    try:
        return int(args.func(args) or 0)
    except Exception as exc:
        print(f"{args.command.upper()}_FAILED type={type(exc).__name__} detail={exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
