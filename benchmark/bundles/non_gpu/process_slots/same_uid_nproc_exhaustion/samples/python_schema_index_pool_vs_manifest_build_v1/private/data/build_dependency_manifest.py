#!/usr/bin/env python3
"""Analyze Python modules with a fixed worker cohort and write a manifest."""

import argparse
import ast
import errno
import hashlib
import json
import os
import pathlib
import resource
import shutil
import sys
import time


def atomic_json(path, value):
    path = pathlib.Path(path)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    os.replace(temporary, path)


def proc_limit(tid):
    for line in pathlib.Path(f"/proc/{tid}/limits").read_text().splitlines():
        if line.startswith("Max processes"):
            values = line.split()
            return {"soft": values[2], "hard": values[3]}
    raise RuntimeError("Max processes row missing")


def uid_tasks(uid):
    tasks = []
    for process in pathlib.Path("/proc").iterdir():
        if not process.name.isdigit():
            continue
        try:
            task_paths = list((process / "task").iterdir())
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        for task_path in task_paths:
            try:
                status = {
                    line.split(":", 1)[0]: line.split(":", 1)[1].strip()
                    for line in (task_path / "status").read_text().splitlines()
                    if ":" in line
                }
                if int(status["Uid"].split()[0]) != uid:
                    continue
                tasks.append(
                    {
                        "tid": int(status["Pid"]),
                        "tgid": int(status["Tgid"]),
                        "ppid": int(status["PPid"]),
                        "name": status["Name"],
                        "rlimit_nproc": proc_limit(status["Pid"]),
                    }
                )
            except (
                FileNotFoundError,
                KeyError,
                PermissionError,
                ProcessLookupError,
                RuntimeError,
                ValueError,
            ):
                continue
    return sorted(tasks, key=lambda item: item["tid"])


def analyze(path, source_root):
    source = path.read_text()
    tree = ast.parse(source, filename=str(path))
    symbols = []
    imports = []
    for node in ast.walk(tree):
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            symbols.append({"name": node.name, "line": node.lineno, "kind": type(node).__name__})
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


def worker(index, worker_count, files, source_root, output, gate, owner_uid):
    token = os.read(gate, 1)
    os.close(gate)
    if token != b"G" or os.getuid() != owner_uid:
        return 91
    modules = [
        analyze(path, source_root)
        for position, path in enumerate(files)
        if position % worker_count == index
    ]
    atomic_json(
        pathlib.Path(output) / f"worker-{index:02d}.json",
        {"worker": index, "pid": os.getpid(), "uid": os.getuid(), "modules": modules},
    )
    return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--workers", type=int, required=True)
    parser.add_argument("--owner-uid", type=int, required=True)
    parser.add_argument("--limit", type=int, required=True)
    args = parser.parse_args()
    source_root = pathlib.Path(args.source)
    output = pathlib.Path(args.output)
    if os.getuid() != args.owner_uid:
        print(f"DEPENDENCY_MANIFEST_OK=0 reason=wrong_uid actual={os.getuid()} required={args.owner_uid}")
        return 73
    if args.limit < 1 or args.workers < 1:
        print("DEPENDENCY_MANIFEST_OK=0 reason=invalid_input")
        return 74
    try:
        resource.setrlimit(resource.RLIMIT_NPROC, (args.limit, args.limit))
    except (OSError, ValueError) as error:
        print(f"DEPENDENCY_MANIFEST_OK=0 reason=limit_setup_failed error={error}")
        return 76
    soft, hard = resource.getrlimit(resource.RLIMIT_NPROC)
    if (soft, hard) != (args.limit, args.limit):
        print(f"DEPENDENCY_MANIFEST_OK=0 reason=limit_not_inherited actual={soft}:{hard} required={args.limit}:{args.limit}")
        return 77
    files = sorted(source_root.rglob("*.py"))
    if not files:
        print("DEPENDENCY_MANIFEST_OK=0 reason=invalid_input")
        return 74
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True, mode=0o700)
    attempt = {
        "complete": False,
        "uid": os.getuid(),
        "rlimit_nproc": [soft, hard],
        "required_workers": args.workers,
        "module_count": len(files),
        "started_at_ns": time.time_ns(),
    }
    read_fd, write_fd = os.pipe()
    children = []
    spawn_error = None
    for index in range(args.workers):
        try:
            pid = os.fork()
        except OSError as error:
            spawn_error = error
            break
        if pid == 0:
            os.close(write_fd)
            code = worker(index, args.workers, files, source_root, output, read_fd, args.owner_uid)
            os._exit(code)
        children.append(pid)
    os.close(read_fd)
    attempt["launched_workers"] = len(children)
    attempt["cohort_pids"] = [os.getpid(), *children]
    attempt["uid_task_inventory_at_cohort"] = uid_tasks(args.owner_uid)
    attempt["uid_task_count_at_cohort"] = len(attempt["uid_task_inventory_at_cohort"])
    if spawn_error is not None:
        attempt["spawn_errno"] = spawn_error.errno
        attempt["spawn_error"] = spawn_error.strerror
        attempt["error"] = "required_worker_cohort_not_reached"
        os.close(write_fd)
        for pid in children:
            os.waitpid(pid, 0)
        atomic_json(output / "attempt.json", attempt)
        print(
            f"DEPENDENCY_MANIFEST_OK=0 launched={len(children)} required={args.workers} "
            f"errno={spawn_error.errno} uid_tasks={attempt['uid_task_count_at_cohort']}"
        )
        return 75 if spawn_error.errno == errno.EAGAIN else 79
    os.write(write_fd, b"G" * len(children))
    os.close(write_fd)
    failures = []
    for pid in children:
        _, status = os.waitpid(pid, 0)
        code = os.waitstatus_to_exitcode(status)
        if code != 0:
            failures.append({"pid": pid, "exit_code": code})
    if failures:
        attempt["error"] = "worker_failed"
        attempt["worker_failures"] = failures
        atomic_json(output / "attempt.json", attempt)
        print(f"DEPENDENCY_MANIFEST_OK=0 reason=worker_failed count={len(failures)}")
        return 80
    shards = [json.loads((output / f"worker-{index:02d}.json").read_text()) for index in range(args.workers)]
    modules = sorted([module for shard in shards for module in shard["modules"]], key=lambda item: item["module"])
    edges = sorted({(module["module"], imported) for module in modules for imported in module["imports"]})
    graph = {
        "complete": len(modules) == len(files),
        "module_count": len(modules),
        "symbol_count": sum(len(module["symbols"]) for module in modules),
        "modules": modules,
        "import_edges": [{"source": source, "target": target} for source, target in edges],
    }
    atomic_json(output / "dependency-manifest.json", graph)
    summary = {
        "complete": graph["complete"],
        "worker_count": args.workers,
        "module_count": len(modules),
        "symbol_count": graph["symbol_count"],
        "owner_uid": os.getuid(),
        "rlimit_nproc": [soft, hard],
    }
    atomic_json(output / "build-summary.json", summary)
    attempt.update(complete=graph["complete"], owner_uid=os.getuid(), finished_at_ns=time.time_ns())
    atomic_json(output / "attempt.json", attempt)
    print(
        f"DEPENDENCY_MANIFEST_OK=1 workers={args.workers} modules={len(modules)} "
        f"symbols={graph['symbol_count']} owner_uid={os.getuid()}"
    )
    return 0 if graph["complete"] else 81


if __name__ == "__main__":
    raise SystemExit(main())
