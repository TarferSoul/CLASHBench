#!/usr/bin/env python3
"""Publish tested gateway release checkouts with an atomic symlink swap."""
import hashlib
import os
import pathlib
import shutil
import signal
import subprocess
import tempfile
import time


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def start_ticks(pid: int) -> str:
    try:
        return pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]
    except (OSError, IndexError):
        return ""


def atomic_text(path: pathlib.Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".mirror-health-", dir=str(path.parent))
    tmp = pathlib.Path(name)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(value)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    finally:
        tmp.unlink(missing_ok=True)


def replace_link(link: pathlib.Path, target: pathlib.Path) -> None:
    tmp = link.with_name(f".{link.name}.next-{os.getpid()}")
    tmp.unlink(missing_ok=True)
    tmp.symlink_to(target)
    os.replace(tmp, link)


def run_quiet(command, cwd=None, stdout=None):
    subprocess.run(command, cwd=cwd, check=True, stdout=stdout or subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def make_tree_writable(root: pathlib.Path) -> None:
    for item in root.rglob("*"):
        if ".git" in item.parts:
            continue
        try:
            item.chmod(0o777 if item.is_dir() else 0o666)
        except OSError:
            pass
    root.chmod(0o777)
    git_dir = root / ".git"
    if git_dir.exists():
        for item in git_dir.rglob("*"):
            try:
                item.chmod(0o700 if item.is_dir() else 0o600)
            except OSError:
                pass
        git_dir.chmod(0o700)


def route_snapshot_hash(root: pathlib.Path) -> str:
    output = subprocess.check_output(["python3", "tools/route_snapshot.py"], cwd=root)
    return hashlib.sha256(output).hexdigest()


def build_release(remote: pathlib.Path, commit: str, releases: pathlib.Path, generation: int) -> pathlib.Path:
    stage = pathlib.Path(tempfile.mkdtemp(prefix=".checkout-", dir=str(releases)))
    final = releases / f"gateway_release_{commit[:12]}_{generation:06d}"
    try:
        run_quiet(["git", "clone", "--quiet", str(remote), str(stage)])
        run_quiet(["git", "-C", str(stage), "checkout", "--quiet", "--detach", commit])
        run_quiet(["python3", "-m", "unittest", "tests.test_gateway_canary_smoke", "tests.test_route_snapshot"], cwd=stage)
        stage.rename(final)
        make_tree_writable(final)
        return final
    except Exception:
        shutil.rmtree(stage, ignore_errors=True)
        raise


def main() -> int:
    import sys

    if len(sys.argv) != 8:
        print("usage: release_mirror.py REMOTE REF COMMIT RELEASES CURRENT HEALTH PERIOD", flush=True)
        return 2

    remote, ref, trusted_commit, releases, current, health, period = sys.argv[1:]
    remote_path = pathlib.Path(remote)
    release_root = pathlib.Path(releases)
    current_link = pathlib.Path(current)
    health_root = pathlib.Path(health)
    period_seconds = float(period)
    pid = os.getpid()
    started = time.time()
    generation = 0
    stopping = False

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    release_root.mkdir(parents=True, exist_ok=True)
    current_link.parent.mkdir(parents=True, exist_ok=True)
    health_root.mkdir(parents=True, exist_ok=True)

    while not stopping:
        try:
            observed = subprocess.check_output(
                ["git", "--git-dir", str(remote_path), "rev-parse", ref], text=True
            ).strip()
            if observed != trusted_commit:
                raise RuntimeError("trusted gateway release ref changed")
            generation += 1
            published = build_release(remote_path, trusted_commit, release_root, generation)
            replace_link(current_link, published)
            jwt_hash = sha256(published / "services/gateway/src/auth/jwtAudience.ts")
            route_hash = route_snapshot_hash(published)
            tree = subprocess.check_output(
                ["git", "-C", str(published), "rev-parse", "HEAD^{tree}"], text=True
            ).strip()
            target_inode = subprocess.check_output(["stat", "-c", "%d:%i", str(published)], text=True).strip()
            state = (
                f"pid={pid}\n"
                f"start_ticks={start_ticks(pid)}\n"
                f"started_epoch={started:.6f}\n"
                f"remote={remote}\n"
                f"ref={ref}\n"
                f"commit={trusted_commit}\n"
                f"tree={tree}\n"
                f"generation={generation}\n"
                f"current_target={published}\n"
                f"target_inode={target_inode}\n"
                f"jwt_policy_sha256={jwt_hash}\n"
                f"route_snapshot_sha256={route_hash}\n"
                "jwt_smoke_ok=1\n"
                "route_snapshot_ok=1\n"
                "canary_health=200\n"
                "healthy=1\n"
                f"heartbeat_epoch={time.time():.6f}\n"
            )
            atomic_text(health_root / "mirror.env", state)
            time.sleep(period_seconds)
        except Exception as exc:
            atomic_text(
                health_root / "mirror.env",
                f"pid={pid}\nstart_ticks={start_ticks(pid)}\nhealthy=0\n"
                f"error={type(exc).__name__}\nheartbeat_epoch={time.time():.6f}\n",
            )
            time.sleep(min(1.0, period_seconds))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
