#!/usr/bin/env python3
import argparse
import fcntl
import hashlib
import html
import json
import os
import pathlib
import re
import shutil
import signal
import sys
import time
import zipfile


DEFAULT_REPO = pathlib.Path("/srv/wheelhouse-cache")
DEFAULT_A_LOCK = pathlib.Path("/run/lock/wheelhouse-cache-reconciler.lock")
DEFAULT_B_LOCK = pathlib.Path("/var/lock/wheelhouse-cache.lock")
DEFAULT_STATUS = pathlib.Path("/run/wheelhouse-cache/status.json")
DEFAULT_PID_FILE = pathlib.Path("/run/wheelhouse-cache/reconciler.pid")

STOP = False


def sha256_file(path):
    digest = hashlib.sha256()
    with pathlib.Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_text(path, text, mode=0o644):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    tmp.write_text(text, encoding="utf-8")
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def atomic_json(path, value, mode=0o644):
    atomic_text(path, json.dumps(value, indent=2, sort_keys=True) + "\n", mode=mode)


def normalize_project(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def wheel_name_parts(path):
    name = pathlib.Path(path).name
    suffix = "-py3-none-any.whl"
    if not name.endswith(suffix) or "-" not in name[: -len(suffix)]:
        raise ValueError(f"unsupported wheel filename: {name}")
    stem = name[: -len(suffix)]
    project, version = stem.rsplit("-", 1)
    return project, version


def read_manifest(repo):
    path = pathlib.Path(repo) / "manifest.json"
    if not path.exists():
        return {"manifest_generation": 0, "packages": {}, "last_index_hash": ""}
    return json.loads(path.read_text(encoding="utf-8"))


def write_project_index(repo, normalized):
    repo = pathlib.Path(repo)
    pool = repo / "pool" / normalized
    simple = repo / "simple" / normalized
    simple.mkdir(parents=True, exist_ok=True)
    lines = ["<!doctype html>", "<html><body>"]
    for wheel in sorted(pool.glob("*.whl")):
        digest = sha256_file(wheel)
        href = f"../../pool/{normalized}/{html.escape(wheel.name)}#sha256={digest}"
        lines.append(f'<a href="{href}">{html.escape(wheel.name)}</a><br/>')
    lines.append("</body></html>")
    content = "\n".join(lines) + "\n"
    index = simple / "index.html"
    atomic_text(index, content)
    return index, hashlib.sha256(content.encode("utf-8")).hexdigest()


def publish_wheel(repo, wheel_path, expected_sha, actor):
    repo = pathlib.Path(repo)
    wheel_path = pathlib.Path(wheel_path)
    project, version = wheel_name_parts(wheel_path)
    normalized = normalize_project(project)
    actual_sha = sha256_file(wheel_path)
    if actual_sha != expected_sha:
        raise RuntimeError(f"sha256 mismatch for {wheel_path.name}")

    pool = repo / "pool" / normalized
    pool.mkdir(parents=True, exist_ok=True)
    target = pool / wheel_path.name
    shutil.copy2(wheel_path, target)
    index, index_hash = write_project_index(repo, normalized)

    manifest = read_manifest(repo)
    manifest["manifest_generation"] = int(manifest.get("manifest_generation", 0)) + 1
    manifest["last_index_hash"] = index_hash
    packages = manifest.setdefault("packages", {})
    entries = [item for item in packages.get(normalized, []) if item.get("filename") != wheel_path.name]
    entries.append({
        "filename": wheel_path.name,
        "version": version,
        "sha256": actual_sha,
        "actor": actor,
        "published_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    })
    packages[normalized] = sorted(entries, key=lambda item: item["filename"])
    atomic_json(repo / "manifest.json", manifest)
    return {
        "package": project,
        "normalized_package": normalized,
        "version": version,
        "wheel_sha256": actual_sha,
        "repaired_index_path": str(index),
        "manifest_generation": manifest["manifest_generation"],
        "last_index_hash": index_hash,
    }


def read_expected_sha(wheel_path):
    sha_path = pathlib.Path(str(wheel_path) + ".sha256")
    if not sha_path.exists():
        raise RuntimeError(f"missing checksum sidecar: {sha_path}")
    fields = sha_path.read_text(encoding="utf-8").split()
    if not fields or not re.fullmatch(r"[0-9a-f]{64}", fields[0]):
        raise RuntimeError(f"invalid checksum sidecar: {sha_path}")
    return fields[0]


def open_lock(path, timeout):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o666)
    try:
        os.chmod(path, 0o666)
    except PermissionError:
        pass
    deadline = time.monotonic() + timeout
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except BlockingIOError:
            if time.monotonic() >= deadline:
                os.close(fd)
                raise TimeoutError(f"LOCK_BUSY path={path} timeout={timeout}")
            time.sleep(0.05)


def lock_identity(path):
    stat = os.stat(path)
    return {
        "lock_path": str(path),
        "lock_target": os.path.realpath(path),
        "lock_device_major": os.major(stat.st_dev),
        "lock_device_minor": os.minor(stat.st_dev),
        "lock_inode": stat.st_ino,
    }


def create_fixture_wheel(package, version, output_dir):
    output_dir = pathlib.Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    filename = f"{package}-{version}-py3-none-any.whl"
    path = output_dir / filename
    dist = f"{package}-{version}.dist-info"
    module_name = package.replace("-", "_")
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(f"{module_name}/__init__.py", f"__version__ = {version!r}\n")
        archive.writestr(f"{dist}/METADATA", f"Name: {package}\nVersion: {version}\n")
        archive.writestr(f"{dist}/WHEEL", "Wheel-Version: 1.0\nRoot-Is-Purelib: true\nTag: py3-none-any\n")
        archive.writestr(f"{dist}/RECORD", "")
    digest = sha256_file(path)
    atomic_text(pathlib.Path(str(path) + ".sha256"), f"{digest}  {filename}\n")
    print(json.dumps({"wheel": str(path), "sha256": digest}, sort_keys=True))


def status_payload(status_path, repo, lock_path, heartbeat, phase, processed):
    manifest = read_manifest(repo)
    return {
        "pid": os.getpid(),
        "start_time": proc_start_time(os.getpid()),
        "heartbeat_seq": heartbeat,
        "manifest_generation": int(manifest.get("manifest_generation", 0)),
        "processed_wheels": processed,
        "last_index_hash": manifest.get("last_index_hash", ""),
        "phase": phase,
        **lock_identity(lock_path),
        "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }


def proc_start_time(pid):
    stat = pathlib.Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
    return int(stat.rsplit(") ", 1)[1].split()[19])


def signal_stop(_signum, _frame):
    global STOP
    STOP = True


def run_controller(args):
    signal.signal(signal.SIGTERM, signal_stop)
    signal.signal(signal.SIGINT, signal_stop)
    repo = pathlib.Path(args.repo)
    incoming = pathlib.Path(args.incoming)
    processed_dir = incoming / "processed"
    status = pathlib.Path(args.status)
    status.parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.pid_file).parent.mkdir(parents=True, exist_ok=True)
    atomic_text(args.pid_file, f"{os.getpid()}\n", mode=0o644)

    fd = open_lock(args.lock, timeout=30.0)
    heartbeat = 0
    processed = 0
    try:
        while not STOP:
            heartbeat += 1
            atomic_json(status, status_payload(status, repo, pathlib.Path(args.lock), heartbeat, "scanning", processed))
            wheels = [item for item in sorted(incoming.glob("*.whl")) if item.is_file()]
            if not wheels:
                atomic_json(status, status_payload(status, repo, pathlib.Path(args.lock), heartbeat, "idle", processed))
                time.sleep(args.interval)
                continue
            for wheel in wheels:
                if STOP:
                    break
                heartbeat += 1
                atomic_json(status, status_payload(status, repo, pathlib.Path(args.lock), heartbeat, "publishing", processed))
                expected = read_expected_sha(wheel)
                publish_wheel(repo, wheel, expected, actor="cache-reconciler")
                processed += 1
                processed_dir.mkdir(parents=True, exist_ok=True)
                shutil.move(str(wheel), processed_dir / wheel.name)
                sidecar = pathlib.Path(str(wheel) + ".sha256")
                if sidecar.exists():
                    shutil.move(str(sidecar), processed_dir / sidecar.name)
                heartbeat += 1
                atomic_json(status, status_payload(status, repo, pathlib.Path(args.lock), heartbeat, "idle", processed))
                time.sleep(args.interval)
        atomic_json(status, status_payload(status, repo, pathlib.Path(args.lock), heartbeat + 1, "stopping", processed))
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def run_repair(args):
    if not args.once:
        print("repair requires --once", file=sys.stderr)
        return 2
    staged = pathlib.Path(args.staged_wheel)
    expected = read_expected_sha(staged)
    try:
        fd = open_lock(args.lock, timeout=args.timeout)
    except TimeoutError as exc:
        print(str(exc), file=sys.stderr)
        return 75
    try:
        details = publish_wheel(args.repo, staged, expected, actor="one-shot-repair")
        details.update(lock_identity(pathlib.Path(args.lock)))
        details["repair_command"] = "wheelhousectl repair --once"
        details["verified_hash_sidecar"] = str(staged) + ".sha256"
        atomic_json(args.report, details)
        print(json.dumps(details, sort_keys=True))
        return 0
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def main(argv=None):
    parser = argparse.ArgumentParser(prog="wheelhousectl")
    sub = parser.add_subparsers(dest="command", required=True)

    make = sub.add_parser("make-fixture-wheel")
    make.add_argument("--package", required=True)
    make.add_argument("--version", required=True)
    make.add_argument("--output-dir", required=True)

    controller = sub.add_parser("controller")
    controller.add_argument("--repo", default=str(DEFAULT_REPO))
    controller.add_argument("--incoming", default=str(DEFAULT_REPO / "incoming"))
    controller.add_argument("--lock", default=str(DEFAULT_A_LOCK))
    controller.add_argument("--status", default=str(DEFAULT_STATUS))
    controller.add_argument("--pid-file", default=str(DEFAULT_PID_FILE))
    controller.add_argument("--interval", type=float, default=0.25)

    repair = sub.add_parser("repair")
    repair.add_argument("--once", action="store_true")
    repair.add_argument("--repo", default=str(DEFAULT_REPO))
    repair.add_argument("--lock", default=str(DEFAULT_B_LOCK))
    repair.add_argument("--staged-wheel", required=True)
    repair.add_argument("--report", required=True)
    repair.add_argument("--timeout", type=float, default=3.0)

    args = parser.parse_args(argv)
    if args.command == "make-fixture-wheel":
        create_fixture_wheel(args.package, args.version, args.output_dir)
        return 0
    if args.command == "controller":
        run_controller(args)
        return 0
    if args.command == "repair":
        return run_repair(args)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
