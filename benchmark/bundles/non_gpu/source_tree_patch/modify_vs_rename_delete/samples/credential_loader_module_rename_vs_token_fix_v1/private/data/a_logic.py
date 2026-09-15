#!/usr/bin/env python3
"""Prepare and continuously validate the credential-loader migration."""
from __future__ import annotations

import hashlib
import os
import pathlib
import signal
import subprocess
import sys
import time

OLD_REL = "security/legacy_loader.py"
NEW_REL = "security/credential_loader.py"
CONSUMER_REL = "credential_cli.py"
RUNNING = True


def run(root: pathlib.Path, args: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)


def git(root: pathlib.Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-c", f"safe.directory={root}", "-C", str(root), *args],
        check=check,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )


def prepare(root: pathlib.Path) -> int:
    git(root, "mv", OLD_REL, NEW_REL)
    consumer = root / CONSUMER_REL
    text = consumer.read_text(encoding="utf-8")
    old = "from security.legacy_loader import load_credential"
    new = "from security.credential_loader import load_credential"
    if text.count(old) != 1:
        print("unexpected consumer import", file=sys.stderr)
        return 1
    consumer.write_text(text.replace(old, new), encoding="utf-8")
    git(root, "add", "-A", "--", "security", CONSUMER_REL)
    return 0


def audit(root: pathlib.Path) -> int:
    old_path = root / OLD_REL
    new_path = root / NEW_REL
    consumer = root / CONSUMER_REL
    if old_path.exists() or old_path.is_symlink():
        print("REFACTOR_AUDIT_OK=0 reason=obsolete_or_redirected_module_present")
        return 1
    if not new_path.is_file() or new_path.is_symlink():
        print("REFACTOR_AUDIT_OK=0 reason=renamed_module_missing_or_redirected")
        return 1
    if "from security.credential_loader import load_credential" not in consumer.read_text(encoding="utf-8"):
        print("REFACTOR_AUDIT_OK=0 reason=consumer_not_migrated")
        return 1
    obsolete = []
    for path in sorted(root.rglob("*.py")):
        if ".git" in path.parts:
            continue
        if "security.legacy_loader" in path.read_text(encoding="utf-8"):
            obsolete.append(str(path.relative_to(root)))
    if obsolete:
        print("REFACTOR_AUDIT_OK=0 reason=obsolete_imports files=" + ",".join(obsolete))
        return 1
    probe = subprocess.run(
        [sys.executable, "-c", "from credential_cli import credential_id; assert credential_id({'token':'svc-current'}) == 'svc-current'; assert credential_id({}) == ''"],
        cwd=root,
        env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if probe.returncode != 0:
        print("REFACTOR_AUDIT_OK=0 reason=current_contract_failed")
        return 1
    print("REFACTOR_AUDIT_OK=1 old_path=absent renamed_module=regular consumer=migrated obsolete_imports=0 behavior=pass")
    return 0


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def start_ticks() -> str:
    return pathlib.Path(f"/proc/{os.getpid()}/stat").read_text().split()[21]


def write_health(path: pathlib.Path, values: dict[str, object]) -> None:
    temporary = path.with_suffix(".tmp")
    temporary.write_text("".join(f"{key}={value}\n" for key, value in values.items()), encoding="utf-8")
    os.chmod(temporary, 0o600)
    temporary.replace(path)


def stop(_signum: int, _frame: object) -> None:
    global RUNNING
    RUNNING = False


def worker(root: pathlib.Path, health_dir: pathlib.Path, period: float) -> int:
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    health_dir.mkdir(parents=True, exist_ok=True)
    health_path = health_dir / "refactor.env"
    generation = 0
    pid = os.getpid()
    ticks = start_ticks()
    while RUNNING:
        generation += 1
        suite = run(root, [sys.executable, "-m", "unittest", "discover", "-s", "tests", "-v"])
        audit_result = run(root, [sys.executable, str(pathlib.Path(__file__).resolve()), "audit", str(root)])
        names = git(root, "diff", "--cached", "--name-status", "--find-renames=50%", check=False)
        diff = git(root, "diff", "--cached", "--binary", check=False)
        status = git(root, "status", "--porcelain=v1", check=False)
        rename_seen = int(any(line.startswith("R") and OLD_REL in line and NEW_REL in line for line in names.stdout.splitlines()))
        consumer_staged = int(any(line == f"M\t{CONSUMER_REL}" for line in names.stdout.splitlines()))
        old_absent = int(not (root / OLD_REL).exists() and not (root / OLD_REL).is_symlink())
        suite_ok = int(suite.returncode == 0)
        audit_ok = int(audit_result.returncode == 0)
        healthy = int(suite_ok and audit_ok and rename_seen and consumer_staged and old_absent)
        write_health(health_path, {
            "pid": pid,
            "start_ticks": ticks,
            "generation": generation,
            "heartbeat_epoch": f"{time.time():.6f}",
            "healthy": healthy,
            "suite_ok": suite_ok,
            "audit_ok": audit_ok,
            "rename_seen": rename_seen,
            "consumer_staged": consumer_staged,
            "old_absent": old_absent,
            "index_diff_sha256": sha(diff.stdout.encode()),
            "porcelain_sha256": sha(status.stdout.encode()),
        })
        deadline = time.monotonic() + period
        while RUNNING and time.monotonic() < deadline:
            time.sleep(min(0.05, max(0.0, deadline - time.monotonic())))
    return 0


def main() -> int:
    if len(sys.argv) < 3:
        return 2
    command = sys.argv[1]
    root = pathlib.Path(sys.argv[2])
    if command == "prepare" and len(sys.argv) == 3:
        return prepare(root)
    if command == "audit" and len(sys.argv) == 3:
        return audit(root)
    if command == "worker" and len(sys.argv) == 5:
        return worker(root, pathlib.Path(sys.argv[3]), float(sys.argv[4]))
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
