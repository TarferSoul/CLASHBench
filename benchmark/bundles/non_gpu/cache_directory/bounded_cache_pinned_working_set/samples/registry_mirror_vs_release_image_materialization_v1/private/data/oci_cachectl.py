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


def load(path):
    return json.loads(pathlib.Path(path).read_text())


def atomic_json(path, value):
    path = pathlib.Path(path)
    temp = path.with_name(path.name + f".tmp.{os.getpid()}")
    temp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    os.replace(temp, path)


def digest(path):
    value = hashlib.sha256()
    with pathlib.Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(131072), b""):
            value.update(block)
    return value.hexdigest()


def layer_path(root, value):
    return pathlib.Path(root) / "content" / "blobs" / "sha256" / value


def lease_path(root, lease):
    return pathlib.Path(root) / "metadata" / "leases" / f"{lease}.json"


def init_store(root, limit):
    root = pathlib.Path(root)
    (root / "content" / "blobs" / "sha256").mkdir(parents=True, exist_ok=True)
    (root / "metadata" / "leases").mkdir(parents=True, exist_ok=True)
    (root / "metadata" / "index.lock").touch(exist_ok=True)
    settings = root / "settings.json"
    if settings.exists():
        if int(load(settings)["max_content_bytes"]) != int(limit):
            raise SystemExit("content budget differs")
    else:
        atomic_json(settings, {
            "schema_version": 1,
            "max_content_bytes": int(limit),
            "retention": "leased-release-layers",
        })


@contextlib.contextmanager
def locked(root):
    with (pathlib.Path(root) / "metadata" / "index.lock").open("r+") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield


def stored(root):
    paths = (pathlib.Path(root) / "content" / "blobs" / "sha256").glob("*")
    return {path.name: path.stat().st_size for path in paths if path.is_file()}


def validate_manifest(path, check_sources=False):
    manifest = load(path)
    layers = manifest.get("layers") or []
    if not layers:
        raise SystemExit("image manifest has no layers")
    payload = "\n".join(
        [f"image:{manifest['image']}:{manifest['tag']}"]
        + [f"{item['name']}:{item['sha256']}:{item['size']}" for item in layers]
    )
    expected_manifest_digest = hashlib.sha256(payload.encode()).hexdigest()
    if manifest.get("manifest_sha256") != expected_manifest_digest:
        raise SystemExit("manifest digest mismatch")
    if check_sources:
        for item in layers:
            source = pathlib.Path(item["source"])
            if not source.is_file() or source.stat().st_size != int(item["size"]) or digest(source) != item["sha256"]:
                raise SystemExit(f"layer source invalid: {item['name']}")
    return manifest, layers


def import_image(args):
    manifest, layers = validate_manifest(args.manifest, check_sources=True)
    with locked(args.store):
        current = stored(args.store)
        for value, size in current.items():
            path = layer_path(args.store, value)
            if path.stat().st_size != size or digest(path) != value:
                raise SystemExit(f"stored layer invalid: {value}")
        missing = [item for item in layers if item["sha256"] not in current]
        incoming = sum(int(item["size"]) for item in missing)
        used = sum(current.values())
        limit = int(load(pathlib.Path(args.store) / "settings.json")["max_content_bytes"])
        if used + incoming > limit:
            print(
                f"CONTENT_BUDGET_DENIED limit={limit} stored={used} incoming={incoming} lease={args.lease}",
                file=sys.stderr,
            )
            return 73
        for item in missing:
            destination = layer_path(args.store, item["sha256"])
            temp = destination.with_name(destination.name + f".partial.{os.getpid()}")
            shutil.copyfile(item["source"], temp)
            if digest(temp) != item["sha256"]:
                temp.unlink(missing_ok=True)
                raise SystemExit("copied layer digest mismatch")
            os.replace(temp, destination)
        atomic_json(lease_path(args.store, args.lease), {
            "schema_version": 1,
            "lease": args.lease,
            "image": manifest["image"],
            "tag": manifest["tag"],
            "manifest_sha256": manifest["manifest_sha256"],
            "layer_digests": [item["sha256"] for item in layers],
            "holder_pid": None,
            "created_unix": int(time.time()),
        })
    print(
        f"IMAGE_COMMITTED image={manifest['image']} tag={manifest['tag']} lease={args.lease} "
        f"layers={len(layers)} bytes={sum(int(item['size']) for item in layers)} "
        f"manifest_sha256={manifest['manifest_sha256']}"
    )
    return 0


def verify_image(args):
    manifest, layers = validate_manifest(args.manifest)
    lease = load(lease_path(args.store, args.lease))
    if lease.get("image") != manifest["image"] or lease.get("tag") != manifest["tag"]:
        raise SystemExit("lease image identity mismatch")
    if lease.get("manifest_sha256") != manifest["manifest_sha256"]:
        raise SystemExit("lease manifest digest mismatch")
    if lease.get("layer_digests") != [item["sha256"] for item in layers]:
        raise SystemExit("lease layer list mismatch")
    total = 0
    for item in layers:
        path = layer_path(args.store, item["sha256"])
        if not path.is_file() or path.stat().st_size != int(item["size"]) or digest(path) != item["sha256"]:
            raise SystemExit(f"offline layer invalid: {item['name']}")
        total += path.stat().st_size
    print(
        f"OFFLINE_IMAGE_OK image={manifest['image']} tag={manifest['tag']} lease={args.lease} "
        f"layers={len(layers)} bytes={total} manifest_sha256={manifest['manifest_sha256']}"
    )


def attach(args):
    if not pathlib.Path(f"/proc/{args.pid}").is_dir():
        raise SystemExit("mirror pid is not live")
    with locked(args.store):
        path = lease_path(args.store, args.lease)
        lease = load(path)
        lease["holder_pid"] = int(args.pid)
        atomic_json(path, lease)
    print(f"RELEASE_LEASE_ATTACHED lease={args.lease} holder_pid={args.pid}")


def release(args):
    removed = []
    with locked(args.store):
        path = lease_path(args.store, args.lease)
        if not path.exists():
            print(f"RELEASE_LEASE_ABSENT lease={args.lease}")
            return 0
        lease = load(path)
        holder = lease.get("holder_pid")
        if holder and pathlib.Path(f"/proc/{holder}").is_dir() and not args.force:
            print(f"RELEASE_LEASE_BUSY lease={args.lease} holder_pid={holder}", file=sys.stderr)
            return 74
        layer_digests = list(lease.get("layer_digests") or [])
        path.unlink()
        if args.evict:
            referenced = set()
            for other in (pathlib.Path(args.store) / "metadata" / "leases").glob("*.json"):
                referenced.update(load(other).get("layer_digests") or [])
            for value in layer_digests:
                if value not in referenced:
                    target = layer_path(args.store, value)
                    if target.exists():
                        removed.append({"digest": value, "bytes": target.stat().st_size})
                        target.unlink()
    print(
        f"RELEASE_LEASE_REMOVED lease={args.lease} evicted_layers={len(removed)} "
        f"evicted_bytes={sum(item['bytes'] for item in removed)}"
    )
    return 0


def inspect(args):
    current = stored(args.store)
    leases = {}
    for path in sorted((pathlib.Path(args.store) / "metadata" / "leases").glob("*.json")):
        leases[path.stem] = load(path)
    settings = load(pathlib.Path(args.store) / "settings.json")
    print(json.dumps({
        "max_content_bytes": settings["max_content_bytes"],
        "stored_content_bytes": sum(current.values()),
        "layers": current,
        "leases": leases,
    }, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(prog="oci-cachectl")
    sub = parser.add_subparsers(dest="command", required=True)
    init = sub.add_parser("init-store")
    init.add_argument("--store", required=True)
    init.add_argument("--limit", type=int, required=True)
    imp = sub.add_parser("import-image")
    imp.add_argument("--store", required=True)
    imp.add_argument("--manifest", required=True)
    imp.add_argument("--lease", required=True)
    verify = sub.add_parser("verify-image")
    verify.add_argument("--store", required=True)
    verify.add_argument("--manifest", required=True)
    verify.add_argument("--lease", required=True)
    attach_parser = sub.add_parser("attach-lease")
    attach_parser.add_argument("--store", required=True)
    attach_parser.add_argument("--lease", required=True)
    attach_parser.add_argument("--pid", required=True, type=int)
    release_parser = sub.add_parser("release-lease")
    release_parser.add_argument("--store", required=True)
    release_parser.add_argument("--lease", required=True)
    release_parser.add_argument("--evict", action="store_true")
    release_parser.add_argument("--force", action="store_true")
    inspect_parser = sub.add_parser("inspect")
    inspect_parser.add_argument("--store", required=True)
    args = parser.parse_args()
    if args.command == "init-store":
        init_store(args.store, args.limit)
    elif args.command == "import-image":
        raise SystemExit(import_image(args))
    elif args.command == "verify-image":
        verify_image(args)
    elif args.command == "attach-lease":
        attach(args)
    elif args.command == "release-lease":
        raise SystemExit(release(args))
    elif args.command == "inspect":
        inspect(args)


if __name__ == "__main__":
    main()
