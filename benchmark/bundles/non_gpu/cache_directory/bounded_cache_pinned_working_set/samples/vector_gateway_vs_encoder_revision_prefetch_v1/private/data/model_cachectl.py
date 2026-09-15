#!/usr/bin/env python3
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import pathlib
import shutil
import sys
import time


def read_json(path):
    return json.loads(pathlib.Path(path).read_text())


def write_json(path, value):
    path = pathlib.Path(path)
    temp = path.with_name(path.name + f".tmp.{os.getpid()}")
    temp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    os.replace(temp, path)


def sha256(path):
    digest = hashlib.sha256()
    with pathlib.Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(131072), b""):
            digest.update(block)
    return digest.hexdigest()


def blob_path(cache, digest):
    return pathlib.Path(cache) / "blobs" / "sha256" / digest


def lease_path(cache, lease):
    return pathlib.Path(cache) / "leases" / f"{lease}.json"


def initialize(cache, limit):
    root = pathlib.Path(cache)
    (root / "blobs" / "sha256").mkdir(parents=True, exist_ok=True)
    (root / "leases").mkdir(parents=True, exist_ok=True)
    (root / "index.lock").touch(exist_ok=True)
    config = root / "config.json"
    if config.exists():
        if int(read_json(config)["limit_bytes"]) != int(limit):
            raise SystemExit("configured limit differs")
    else:
        write_json(config, {"schema_version": 1, "limit_bytes": int(limit), "policy": "manifest-atomic"})


@contextlib.contextmanager
def locked(cache):
    with (pathlib.Path(cache) / "index.lock").open("r+") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield


def manifest_artifacts(path):
    manifest = read_json(path)
    artifacts = manifest.get("artifacts") or []
    if not artifacts:
        raise SystemExit("manifest has no artifacts")
    return manifest, artifacts


def validate_source(item):
    source = pathlib.Path(item["source"])
    if not source.is_file() or source.stat().st_size != int(item["size"]) or sha256(source) != item["sha256"]:
        raise SystemExit(f"source integrity mismatch: {item['name']}")


def committed(cache):
    paths = list((pathlib.Path(cache) / "blobs" / "sha256").glob("*"))
    return {path.name: path.stat().st_size for path in paths if path.is_file()}


def fingerprint(artifacts):
    payload = "\n".join(f"{item['name']}:{item['sha256']}:{item['size']}" for item in artifacts)
    return hashlib.sha256(payload.encode()).hexdigest()


def command_import(args):
    manifest, artifacts = manifest_artifacts(args.manifest)
    for item in artifacts:
        validate_source(item)
    with locked(args.cache):
        current = committed(args.cache)
        for digest, size in current.items():
            path = blob_path(args.cache, digest)
            if sha256(path) != digest or path.stat().st_size != size:
                raise SystemExit(f"existing blob integrity mismatch: {digest}")
        missing = [item for item in artifacts if item["sha256"] not in current]
        required = sum(int(item["size"]) for item in missing)
        used = sum(current.values())
        limit = int(read_json(pathlib.Path(args.cache) / "config.json")["limit_bytes"])
        if used + required > limit:
            print(
                f"CACHE_LIMIT_EXCEEDED limit={limit} committed={used} required={required} lease={args.lease}",
                file=sys.stderr,
            )
            return 75
        for item in missing:
            destination = blob_path(args.cache, item["sha256"])
            temp = destination.with_name(destination.name + f".tmp.{os.getpid()}")
            shutil.copyfile(item["source"], temp)
            if sha256(temp) != item["sha256"]:
                temp.unlink(missing_ok=True)
                raise SystemExit("copy integrity mismatch")
            os.replace(temp, destination)
        write_json(
            lease_path(args.cache, args.lease),
            {
                "schema_version": 1,
                "lease": args.lease,
                "revision": manifest["revision"],
                "digests": [item["sha256"] for item in artifacts],
                "holder_pid": None,
                "created_unix": int(time.time()),
            },
        )
    print(
        f"COMMITTED revision={manifest['revision']} lease={args.lease} "
        f"bytes={sum(int(item['size']) for item in artifacts)} fingerprint={fingerprint(artifacts)}"
    )
    return 0


def command_verify(args):
    manifest, artifacts = manifest_artifacts(args.manifest)
    lease = read_json(lease_path(args.cache, args.lease))
    expected = [item["sha256"] for item in artifacts]
    if lease.get("digests") != expected or lease.get("revision") != manifest.get("revision"):
        raise SystemExit("lease does not match manifest")
    total = 0
    for item in artifacts:
        path = blob_path(args.cache, item["sha256"])
        if not path.is_file() or path.stat().st_size != int(item["size"]) or sha256(path) != item["sha256"]:
            raise SystemExit(f"cached blob invalid: {item['name']}")
        total += path.stat().st_size
    print(
        f"OFFLINE_RELOAD_OK revision={manifest['revision']} lease={args.lease} "
        f"bytes={total} fingerprint={fingerprint(artifacts)}"
    )


def command_attach(args):
    if not pathlib.Path(f"/proc/{args.pid}").is_dir():
        raise SystemExit("holder pid is not live")
    with locked(args.cache):
        path = lease_path(args.cache, args.lease)
        lease = read_json(path)
        lease["holder_pid"] = int(args.pid)
        write_json(path, lease)
    print(f"LEASE_ATTACHED lease={args.lease} holder_pid={args.pid}")


def command_release(args):
    removed = []
    with locked(args.cache):
        path = lease_path(args.cache, args.lease)
        if not path.exists():
            print(f"LEASE_ABSENT lease={args.lease}")
            return 0
        lease = read_json(path)
        holder_pid = lease.get("holder_pid")
        if holder_pid and pathlib.Path(f"/proc/{holder_pid}").is_dir() and not args.force:
            print(f"LEASE_IN_USE lease={args.lease} holder_pid={holder_pid}", file=sys.stderr)
            return 76
        digests = list(lease.get("digests") or [])
        path.unlink()
        if args.evict:
            referenced = set()
            for other in (pathlib.Path(args.cache) / "leases").glob("*.json"):
                referenced.update(read_json(other).get("digests") or [])
            for digest in digests:
                if digest not in referenced:
                    target = blob_path(args.cache, digest)
                    if target.exists():
                        removed.append({"digest": digest, "bytes": target.stat().st_size})
                        target.unlink()
    print(
        f"LEASE_RELEASED lease={args.lease} evicted_bytes={sum(x['bytes'] for x in removed)} "
        f"evicted_digests={','.join(x['digest'] for x in removed)}"
    )
    return 0


def command_usage(args):
    current = committed(args.cache)
    leases = {}
    for path in sorted((pathlib.Path(args.cache) / "leases").glob("*.json")):
        leases[path.stem] = read_json(path)
    config = read_json(pathlib.Path(args.cache) / "config.json")
    print(json.dumps({
        "limit_bytes": config["limit_bytes"],
        "committed_bytes": sum(current.values()),
        "entries": current,
        "leases": leases,
    }, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(prog="model-cachectl")
    sub = parser.add_subparsers(dest="command", required=True)
    init = sub.add_parser("init")
    init.add_argument("--cache", required=True)
    init.add_argument("--limit", required=True, type=int)
    imp = sub.add_parser("import-manifest")
    imp.add_argument("--cache", required=True)
    imp.add_argument("--manifest", required=True)
    imp.add_argument("--lease", required=True)
    verify = sub.add_parser("verify-manifest")
    verify.add_argument("--cache", required=True)
    verify.add_argument("--manifest", required=True)
    verify.add_argument("--lease", required=True)
    attach = sub.add_parser("attach-holder")
    attach.add_argument("--cache", required=True)
    attach.add_argument("--lease", required=True)
    attach.add_argument("--pid", required=True, type=int)
    release = sub.add_parser("release")
    release.add_argument("--cache", required=True)
    release.add_argument("--lease", required=True)
    release.add_argument("--evict", action="store_true")
    release.add_argument("--force", action="store_true")
    usage = sub.add_parser("usage")
    usage.add_argument("--cache", required=True)
    args = parser.parse_args()
    if args.command == "init":
        initialize(args.cache, args.limit)
    elif args.command == "import-manifest":
        raise SystemExit(command_import(args))
    elif args.command == "verify-manifest":
        command_verify(args)
    elif args.command == "attach-holder":
        command_attach(args)
    elif args.command == "release":
        raise SystemExit(command_release(args))
    elif args.command == "usage":
        command_usage(args)


if __name__ == "__main__":
    main()
