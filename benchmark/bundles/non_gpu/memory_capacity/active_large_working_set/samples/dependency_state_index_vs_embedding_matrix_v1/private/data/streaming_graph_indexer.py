#!/usr/bin/env python3
"""Maintain an active resident dependency-graph state table and checkpoints."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import sys
import time


MIB = 1024 * 1024
PAGE = 4096
STOP = False


def atomic_json(path: Path, value: dict) -> None:
    tmp = path.with_name(path.name + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def cgroup_dir() -> Path:
    rel = ""
    try:
        for line in Path("/proc/self/cgroup").read_text(encoding="utf-8").splitlines():
            fields = line.split(":")
            if len(fields) == 3 and fields[0] == "0":
                rel = fields[2].strip("/")
                break
    except OSError:
        pass
    return Path("/sys/fs/cgroup") / rel


def read_int(path: Path) -> int | None:
    try:
        text = path.read_text(encoding="utf-8").strip()
    except OSError:
        return None
    if text == "max":
        return None
    try:
        return int(text)
    except ValueError:
        return None


def rss_kib() -> int:
    try:
        for line in Path("/proc/self/status").read_text(encoding="utf-8").splitlines():
            if line.startswith("VmRSS:"):
                return int(line.split()[1])
    except OSError:
        pass
    return 0


def pss_kib() -> int:
    try:
        for line in Path("/proc/self/smaps_rollup").read_text(encoding="utf-8").splitlines():
            if line.startswith("Pss:"):
                return int(line.split()[1])
    except OSError:
        pass
    return 0


def start_time() -> int:
    try:
        return int(Path("/proc/self/stat").read_text(encoding="utf-8").split()[21])
    except (OSError, IndexError, ValueError):
        return 0


def memory_snapshot() -> dict:
    cg = cgroup_dir()
    return {
        "cgroup": str(cg),
        "memory_max": read_int(cg / "memory.max"),
        "memory_current": read_int(cg / "memory.current"),
        "memory_peak": read_int(cg / "memory.peak"),
    }


def handle_signal(signum: int, _frame: object) -> None:
    global STOP
    STOP = True


def touch_state(buf: bytearray, sequence: int, shards: int) -> tuple[str, list[dict]]:
    digest = hashlib.sha256()
    pages = len(buf) // PAGE
    pages_per_shard = max(1, pages // shards)
    shard_rows: list[dict] = []
    rolling = 0
    for page_index in range(pages):
        offset = page_index * PAGE
        value = (sequence * 29 + page_index * 17 + 73) & 0xFF
        buf[offset] = value
        rolling = (rolling + value + sequence + page_index) & 0xFFFFFFFFFFFFFFFF
        if (page_index + 1) % pages_per_shard == 0 or page_index + 1 == pages:
            shard = min(shards - 1, page_index // pages_per_shard)
            shard_rows.append(
                {
                    "shard": shard,
                    "sequence": sequence,
                    "pages_seen": page_index + 1,
                    "checksum": f"{rolling:016x}",
                }
            )
            digest.update(shard.to_bytes(2, "little"))
            digest.update(rolling.to_bytes(8, "little"))
    return digest.hexdigest(), shard_rows


def write_checkpoint(state_dir: Path, args: argparse.Namespace, sequence: int, digest: str, rows: list[dict]) -> None:
    processed_edges = sequence * int(args.synthetic_edges_per_pass)
    payload = {
        "service": "dependency-graph-state-indexer",
        "pid": os.getpid(),
        "pgid": os.getpgrp(),
        "starttime": start_time(),
        "phase": "indexing",
        "state_mib": int(args.state_mib),
        "sequence": sequence,
        "processed_edges": processed_edges,
        "shard_count": int(args.shards),
        "checkpoint_digest": digest,
        "rss_kib": rss_kib(),
        "pss_kib": pss_kib(),
        "memory": memory_snapshot(),
        "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    atomic_json(state_dir / "state.json", payload)
    checkpoint = {
        **payload,
        "shards": rows,
    }
    atomic_json(state_dir / f"checkpoint_{sequence:06d}.json", checkpoint)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--state-mib", type=int, required=True)
    parser.add_argument("--shards", type=int, default=16)
    parser.add_argument("--synthetic-edges-per-pass", type=int, default=902400)
    args = parser.parse_args()

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)

    state_dir = Path(args.state_dir)
    state_dir.mkdir(parents=True, exist_ok=True)
    pid_file = state_dir / "indexer.pid"
    pid_file.write_text(f"{os.getpid()}\n", encoding="utf-8")
    atomic_json(
        state_dir / "state.json",
        {
            "service": "dependency-graph-state-indexer",
            "pid": os.getpid(),
            "pgid": os.getpgrp(),
            "starttime": start_time(),
            "phase": "allocating",
            "state_mib": int(args.state_mib),
            "sequence": 0,
            "processed_edges": 0,
            "rss_kib": rss_kib(),
            "pss_kib": pss_kib(),
            "memory": memory_snapshot(),
            "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        },
    )

    try:
        table = bytearray(int(args.state_mib) * MIB)
    except MemoryError:
        atomic_json(
            state_dir / "state.json",
            {
                "service": "dependency-graph-state-indexer",
                "pid": os.getpid(),
                "phase": "failed",
                "reason": "allocation_failed",
                "state_mib": int(args.state_mib),
                "memory": memory_snapshot(),
                "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            },
        )
        return 82

    sequence = 0
    while not STOP:
        sequence += 1
        digest, rows = touch_state(table, sequence, int(args.shards))
        write_checkpoint(state_dir, args, sequence, digest, rows)
        time.sleep(0.05)

    final = {
        "service": "dependency-graph-state-indexer",
        "pid": os.getpid(),
        "pgid": os.getpgrp(),
        "starttime": start_time(),
        "phase": "stopped",
        "state_mib": int(args.state_mib),
        "sequence": sequence,
        "processed_edges": sequence * int(args.synthetic_edges_per_pass),
        "rss_kib": rss_kib(),
        "pss_kib": pss_kib(),
        "memory": memory_snapshot(),
        "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    atomic_json(state_dir / "stop.json", final)
    atomic_json(state_dir / "state.json", final)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

