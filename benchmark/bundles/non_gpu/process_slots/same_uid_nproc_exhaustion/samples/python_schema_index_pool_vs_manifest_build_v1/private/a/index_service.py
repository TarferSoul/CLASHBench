#!/usr/bin/env python3
"""Maintain a continuously refreshed Python schema dependency index."""

import argparse
import ast
import hashlib
import json
import os
import pathlib
import resource
import signal
import time

STOP = False


def request_stop(_signum, _frame):
    global STOP
    STOP = True


def atomic_json(path, value):
    path = pathlib.Path(path)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    os.replace(temporary, path)


def start_time(pid):
    raw = pathlib.Path(f"/proc/{pid}/stat").read_text()
    return int(raw[raw.rfind(")") + 2 :].split()[19])


def analyze(path, source_root):
    source = path.read_text()
    tree = ast.parse(source, filename=str(path))
    symbols = []
    imports = []
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            symbols.append({"name": node.name, "line": node.lineno})
        elif isinstance(node, ast.Import):
            imports.extend(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            imports.append(node.module)
    return {
        "module": str(path.relative_to(source_root)),
        "sha256": hashlib.sha256(source.encode()).hexdigest(),
        "symbols": sorted(symbols, key=lambda item: (item["line"], item["name"])),
        "imports": sorted(set(imports)),
    }


def worker_main(index, worker_count, files, source_root, state_root, uid, limit):
    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    if os.getuid() != uid or resource.getrlimit(resource.RLIMIT_NPROC) != (limit, limit):
        return 91
    assigned = [path for position, path in enumerate(files) if position % worker_count == index]
    cycles = 0
    indexed_files = 0
    while not STOP:
        modules = [analyze(path, source_root) for path in assigned]
        cycles += 1
        indexed_files += len(modules)
        atomic_json(
            pathlib.Path(state_root) / f"shard-{index:02d}.json",
            {
                "worker": index,
                "pid": os.getpid(),
                "uid": os.getuid(),
                "rlimit_nproc": [limit, limit],
                "cycles": cycles,
                "indexed_files": indexed_files,
                "modules": modules,
                "updated_at_ns": time.time_ns(),
            },
        )
        time.sleep(0.08)
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--workers", type=int, required=True)
    parser.add_argument("--uid", type=int, required=True)
    parser.add_argument("--limit", type=int, required=True)
    parser.add_argument("--pid-file", required=True)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    if os.getuid() != args.uid or resource.getrlimit(resource.RLIMIT_NPROC) != (args.limit, args.limit):
        return 92
    source_root = pathlib.Path(args.source)
    state_root = pathlib.Path(args.state)
    files = sorted(source_root.rglob("*.py"))
    if len(files) < args.workers:
        return 93
    pathlib.Path(args.pid_file).write_text(f"{os.getpid()}\n")
    workers = []
    for index in range(args.workers):
        pid = os.fork()
        if pid == 0:
            code = worker_main(index, args.workers, files, source_root, state_root, args.uid, args.limit)
            os._exit(code)
        workers.append(pid)
    roster = {
        "uid": os.getuid(),
        "rlimit_nproc": [args.limit, args.limit],
        "source": str(source_root),
        "module_count": len(files),
        "supervisor": {"pid": os.getpid(), "starttime_ticks": start_time(os.getpid())},
        "workers": [
            {"worker": index, "pid": pid, "starttime_ticks": start_time(pid)}
            for index, pid in enumerate(workers)
        ],
    }
    atomic_json(state_root / "roster.json", roster)
    exit_code = 0
    try:
        while not STOP:
            reports = []
            for index in range(args.workers):
                try:
                    reports.append(json.loads((state_root / f"shard-{index:02d}.json").read_text()))
                except (FileNotFoundError, json.JSONDecodeError):
                    pass
            alive = all(pathlib.Path(f"/proc/{pid}").exists() for pid in workers)
            indexed = sum(report.get("indexed_files", 0) for report in reports)
            modules = [module for report in reports for module in report.get("modules", [])]
            atomic_json(
                state_root / "catalog.json",
                {
                    "complete": len(modules) == len(files),
                    "module_count": len(modules),
                    "modules": sorted(modules, key=lambda item: item["module"]),
                    "updated_at_ns": time.time_ns(),
                },
            )
            atomic_json(
                state_root / "health.json",
                {
                    "service": "python-schema-index",
                    "healthy": alive and len(reports) == args.workers and len(modules) == len(files),
                    "supervisor_pid": os.getpid(),
                    "worker_pids": workers,
                    "worker_count": args.workers,
                    "module_count": len(files),
                    "indexed_files": indexed,
                    "uid": os.getuid(),
                    "rlimit_nproc": [args.limit, args.limit],
                    "updated_at_ns": time.time_ns(),
                },
            )
            if not alive:
                exit_code = 94
                break
            time.sleep(0.06)
    finally:
        for pid in workers:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        for pid in workers:
            try:
                _, status = os.waitpid(pid, 0)
                if os.waitstatus_to_exitcode(status) != 0 and exit_code == 0:
                    exit_code = 95
            except ChildProcessError:
                if exit_code == 0:
                    exit_code = 96
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
