#!/usr/bin/env python3
"""CowpackFS: a small fixed-capacity extent-backed copy-on-write filesystem."""

import argparse
import contextlib
import copy
import fcntl
import hashlib
import json
import os
import pathlib
import shutil
import sys
import time
import uuid


VERSION = "cowpackfs-1.0"
STRIPE = 65536


class NoSpace(RuntimeError):
    def __init__(self, required, used, capacity):
        super().__init__("fixed COW volume has insufficient allocatable extents")
        self.required = required
        self.used = used
        self.capacity = capacity


def dump_json(value):
    print(json.dumps(value, sort_keys=True, indent=2))


def state_path(volume):
    return pathlib.Path(volume) / "superblock.json"


def data_path(volume):
    return pathlib.Path(volume) / "data.bin"


def write_state(path, state):
    temp = path.with_suffix(".json.tmp")
    temp.write_text(json.dumps(state, sort_keys=True, indent=2) + "\n")
    os.replace(temp, path)


@contextlib.contextmanager
def locked_state(volume, exclusive=True):
    root = pathlib.Path(volume)
    lock_path = root / ".cowpack.lock"
    with lock_path.open("a+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)
        state = json.loads(state_path(root).read_text())
        if state.get("format") != VERSION:
            raise RuntimeError("unsupported CowpackFS format")
        yield state


def referenced_ids(state):
    refs = set()
    for entry in state["current"].values():
        refs.update(entry["extents"])
    for snapshot in state["snapshots"].values():
        for entry in snapshot["files"].values():
            refs.update(entry["extents"])
    return refs


def current_ids(state):
    refs = set()
    for entry in state["current"].values():
        refs.update(entry["extents"])
    return refs


def snapshot_ids(state):
    refs = set()
    for snapshot in state["snapshots"].values():
        for entry in snapshot["files"].values():
            refs.update(entry["extents"])
    return refs


def used_bytes(state):
    return sum(state["extents"][extent]["length"] for extent in referenced_ids(state))


def gc_extents(state):
    keep = referenced_ids(state)
    state["extents"] = {
        extent: info for extent, info in state["extents"].items() if extent in keep
    }


def allocate_offsets(state, lengths):
    occupied = sorted(
        (info["offset"], info["offset"] + info["length"])
        for extent, info in state["extents"].items()
        if extent in referenced_ids(state)
    )
    capacity = state["capacity_bytes"]
    result = []
    cursor = 0
    for length in lengths:
        placed = False
        scan = cursor
        for start, end in occupied:
            if end <= scan:
                continue
            if start - scan >= length:
                result.append(scan)
                occupied.append((scan, scan + length))
                occupied.sort()
                cursor = scan + length
                placed = True
                break
            scan = max(scan, end)
        if not placed:
            if capacity - scan < length:
                raise NoSpace(sum(lengths), used_bytes(state), capacity)
            result.append(scan)
            occupied.append((scan, scan + length))
            occupied.sort()
            cursor = scan + length
    return result


def pattern_bytes(seed, offset, length):
    output = bytearray()
    position = offset
    while len(output) < length:
        stripe_no = position // STRIPE
        stripe_offset = position % STRIPE
        digest = hashlib.sha256(f"{seed}:{stripe_no}".encode()).digest()
        stripe = digest * (STRIPE // len(digest))
        take = min(length - len(output), STRIPE - stripe_offset)
        output.extend(stripe[stripe_offset : stripe_offset + take])
        position += take
    return bytes(output)


def pattern_digest(seed, size):
    digest = hashlib.sha256()
    offset = 0
    while offset < size:
        length = min(1024 * 1024, size - offset)
        digest.update(pattern_bytes(seed, offset, length))
        offset += length
    return digest.hexdigest()


def manifest_payload(spec, artifact_records):
    payload = {
        "schema": spec.get("schema", "cowpack-artifact-set-v1"),
        "release": spec["release"],
        "artifacts": artifact_records,
    }
    return (json.dumps(payload, sort_keys=True, indent=2) + "\n").encode()


def materialize_spec(spec):
    items = []
    records = []
    for artifact in spec["artifacts"]:
        size = int(artifact["size"])
        seed = artifact["seed"]
        digest = pattern_digest(seed, size)
        records.append({"path": artifact["path"], "sha256": digest, "size": size})
        items.append(
            {
                "path": artifact["path"],
                "size": size,
                "sha256": digest,
                "kind": "pattern",
                "seed": seed,
            }
        )
    manifest = manifest_payload(spec, records)
    items.append(
        {
            "path": spec["manifest_path"],
            "size": len(manifest),
            "sha256": hashlib.sha256(manifest).hexdigest(),
            "kind": "literal",
            "content": manifest,
        }
    )
    return items


def item_chunks(item, extent_size):
    chunks = []
    offset = 0
    while offset < item["size"]:
        length = min(extent_size, item["size"] - offset)
        if item["kind"] == "pattern":
            content = pattern_bytes(item["seed"], offset, length)
        else:
            content = item["content"][offset : offset + length]
        chunks.append((offset, content))
        offset += length
    return chunks


def apply_spec(volume, spec_path):
    spec = json.loads(pathlib.Path(spec_path).read_text())
    items = materialize_spec(spec)
    with locked_state(volume) as state:
        if spec.get("volume_label") and spec["volume_label"] != state["label"]:
            raise RuntimeError("spec targets a different COW volume label")
        all_chunks = []
        for item in items:
            all_chunks.extend((item, file_offset, content) for file_offset, content in item_chunks(item, state["extent_size"]))
        lengths = [len(content) for _, _, content in all_chunks]
        required = sum(lengths)
        before = used_bytes(state)
        if before + required > state["capacity_bytes"]:
            raise NoSpace(required, before, state["capacity_bytes"])
        offsets = allocate_offsets(state, lengths)
        new_files = {item["path"]: {"extents": [], "size": item["size"], "sha256": item["sha256"]} for item in items}
        with data_path(volume).open("r+b", buffering=0) as image:
            for (item, _file_offset, content), physical in zip(all_chunks, offsets):
                extent_id = f"e{state['next_extent']:08d}"
                state["next_extent"] += 1
                image.seek(physical)
                image.write(content)
                state["extents"][extent_id] = {
                    "offset": physical,
                    "length": len(content),
                    "sha256": hashlib.sha256(content).hexdigest(),
                }
                new_files[item["path"]]["extents"].append(extent_id)
            image.flush()
            os.fsync(image.fileno())
        state["current"].update(new_files)
        state["generation"] += 1
        gc_extents(state)
        write_state(state_path(volume), state)
        return {
            "applied": sorted(new_files),
            "generation": state["generation"],
            "required_bytes": required,
            "allocated_bytes": used_bytes(state),
            "free_bytes": state["capacity_bytes"] - used_bytes(state),
        }


def root_for(state, snapshot=None):
    if snapshot:
        if snapshot not in state["snapshots"]:
            raise RuntimeError("snapshot not found")
        return state["snapshots"][snapshot]["files"]
    return state["current"]


def hash_entry(volume, state, entry):
    digest = hashlib.sha256()
    with data_path(volume).open("rb", buffering=0) as image:
        for extent_id in entry["extents"]:
            info = state["extents"][extent_id]
            image.seek(info["offset"])
            content = image.read(info["length"])
            if len(content) != info["length"]:
                raise RuntimeError("short extent read")
            if hashlib.sha256(content).hexdigest() != info["sha256"]:
                raise RuntimeError("extent checksum mismatch")
            digest.update(content)
    return digest.hexdigest()


def verify_spec(volume, spec_path, snapshot=None):
    spec = json.loads(pathlib.Path(spec_path).read_text())
    expected = materialize_spec(spec)
    with locked_state(volume, exclusive=False) as state:
        if spec.get("volume_label") and spec["volume_label"] != state["label"]:
            raise RuntimeError("volume label mismatch")
        root = root_for(state, snapshot)
        checked = []
        for item in expected:
            entry = root.get(item["path"])
            if not entry:
                raise RuntimeError(f"missing path {item['path']}")
            if entry["size"] != item["size"] or entry["sha256"] != item["sha256"]:
                raise RuntimeError(f"metadata mismatch {item['path']}")
            observed = hash_entry(volume, state, entry)
            if observed != item["sha256"]:
                raise RuntimeError(f"content checksum mismatch {item['path']}")
            checked.append({"path": item["path"], "size": item["size"], "sha256": observed})
        return {"verified": checked, "snapshot_uuid": snapshot, "volume_label": state["label"]}


def stats(state):
    current = current_ids(state)
    snapshots = snapshot_ids(state)
    allocated = used_bytes(state)
    snapshot_only = snapshots - current
    return {
        "format": state["format"],
        "label": state["label"],
        "capacity_bytes": state["capacity_bytes"],
        "extent_size": state["extent_size"],
        "generation": state["generation"],
        "allocated_bytes": allocated,
        "free_bytes": state["capacity_bytes"] - allocated,
        "current_referenced_bytes": sum(state["extents"][item]["length"] for item in current),
        "snapshot_referenced_bytes": sum(state["extents"][item]["length"] for item in snapshots),
        "snapshot_only_bytes": sum(state["extents"][item]["length"] for item in snapshot_only),
        "snapshot_only_extents": len(snapshot_only),
        "snapshots": [
            {
                "uuid": snapshot_uuid,
                "name": snapshot["name"],
                "generation": snapshot["generation"],
                "file_count": len(snapshot["files"]),
            }
            for snapshot_uuid, snapshot in sorted(state["snapshots"].items())
        ],
    }


def command_format(args):
    root = pathlib.Path(args.volume)
    if root.exists():
        shutil.rmtree(root)
    root.mkdir(parents=True)
    state = {
        "format": VERSION,
        "label": args.label,
        "capacity_bytes": args.capacity,
        "extent_size": args.extent_size,
        "generation": 1,
        "next_extent": 1,
        "current": {},
        "snapshots": {},
        "extents": {},
        "created_unix": int(time.time()),
    }
    with data_path(root).open("wb") as image:
        image.truncate(args.capacity)
    (root / ".cowpack.lock").touch()
    write_state(state_path(root), state)
    dump_json(stats(state))


def command_snapshot_create(args):
    with locked_state(args.volume) as state:
        state["generation"] += 1
        snapshot_uuid = str(uuid.uuid4())
        state["snapshots"][snapshot_uuid] = {
            "name": args.name,
            "generation": state["generation"],
            "created_unix": int(time.time()),
            "files": copy.deepcopy(state["current"]),
        }
        write_state(state_path(args.volume), state)
        dump_json({"uuid": snapshot_uuid, **state["snapshots"][snapshot_uuid], "file_count": len(state["current"])})


def command_snapshot_delete(args):
    with locked_state(args.volume) as state:
        snapshot = state["snapshots"].pop(args.uuid, None)
        if snapshot is None:
            raise RuntimeError("snapshot not found")
        state["generation"] += 1
        gc_extents(state)
        write_state(state_path(args.volume), state)
        dump_json({"deleted_uuid": args.uuid, "generation": state["generation"], "free_bytes": state["capacity_bytes"] - used_bytes(state)})


def command_remove(args):
    with locked_state(args.volume) as state:
        if args.path not in state["current"]:
            raise RuntimeError("path not found")
        del state["current"][args.path]
        state["generation"] += 1
        gc_extents(state)
        write_state(state_path(args.volume), state)
        dump_json({"removed": args.path, "generation": state["generation"]})


def build_parser():
    parser = argparse.ArgumentParser(description=f"CowpackFS {VERSION}")
    parser.add_argument("--version", action="version", version=VERSION)
    commands = parser.add_subparsers(dest="command", required=True)
    fmt = commands.add_parser("format")
    fmt.add_argument("--volume", required=True)
    fmt.add_argument("--capacity", type=int, required=True)
    fmt.add_argument("--extent-size", type=int, required=True)
    fmt.add_argument("--label", required=True)
    fmt.set_defaults(function=command_format)
    apply_cmd = commands.add_parser("apply")
    apply_cmd.add_argument("--volume", required=True)
    apply_cmd.add_argument("--spec", required=True)
    apply_cmd.set_defaults(function=lambda args: dump_json(apply_spec(args.volume, args.spec)))
    verify = commands.add_parser("verify-spec")
    verify.add_argument("--volume", required=True)
    verify.add_argument("--spec", required=True)
    verify.add_argument("--snapshot")
    verify.set_defaults(function=lambda args: dump_json(verify_spec(args.volume, args.spec, args.snapshot)))
    stat_cmd = commands.add_parser("stats")
    stat_cmd.add_argument("--volume", required=True)
    stat_cmd.set_defaults(function=lambda args: locked_stats(args.volume))
    create = commands.add_parser("snapshot-create")
    create.add_argument("--volume", required=True)
    create.add_argument("--name", required=True)
    create.set_defaults(function=command_snapshot_create)
    delete = commands.add_parser("snapshot-delete")
    delete.add_argument("--volume", required=True)
    delete.add_argument("--uuid", required=True)
    delete.set_defaults(function=command_snapshot_delete)
    remove = commands.add_parser("remove")
    remove.add_argument("--volume", required=True)
    remove.add_argument("--path", required=True)
    remove.set_defaults(function=command_remove)
    return parser


def locked_stats(volume):
    with locked_state(volume, exclusive=False) as state:
        dump_json(stats(state))


def main():
    args = build_parser().parse_args()
    try:
        args.function(args)
    except NoSpace as exc:
        print(
            f"ENOSPC required_bytes={exc.required} allocated_bytes={exc.used} "
            f"free_bytes={exc.capacity - exc.used} capacity_bytes={exc.capacity}",
            file=sys.stderr,
        )
        raise SystemExit(28)
    except (OSError, RuntimeError, ValueError, KeyError, json.JSONDecodeError) as exc:
        print(f"COWFS_ERROR={type(exc).__name__}:{exc}", file=sys.stderr)
        raise SystemExit(2)


if __name__ == "__main__":
    main()
