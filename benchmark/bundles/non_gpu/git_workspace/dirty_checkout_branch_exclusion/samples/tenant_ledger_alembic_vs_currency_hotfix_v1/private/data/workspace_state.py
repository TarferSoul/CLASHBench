#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path


GIT_USER = None
TRACKED_FIELDS = [
    "head_ref",
    "head_oid",
    "index_tree",
    "staged_diff_sha256",
    "unstaged_diff_sha256",
    "status_sha256",
    "focused_rc",
    "focused_input_sha256",
]


def run(cmd, check=True, binary=False):
    return subprocess.run(cmd, text=not binary, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=check)


def user_cmd(cmd):
    if GIT_USER and os.geteuid() == 0:
        return ["runuser", "-u", GIT_USER, "--", "env", f"HOME=/home/{GIT_USER}", *cmd]
    return cmd


def git(repo, *args, check=True, binary=False):
    return run(user_cmd(["git", "-C", str(repo), *args]), check=check, binary=binary)


def run_repo_tool(cmd, check=True):
    return run(user_cmd(cmd), check=check)


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def diff_hash(repo, *args):
    return sha256_bytes(git(repo, "diff", "--binary", *args, binary=True).stdout)


def focused_check(repo):
    with tempfile.TemporaryDirectory(prefix="tenant-ledger-state-") as tmp:
        proc = run_repo_tool(
            ["python3", str(repo / "tools" / "check_tenant_ledger_roundtrip.py"), "--repo", str(repo), "--once", "--state-dir", tmp],
            check=False,
        )
    migration = git(repo, "show", ":db/migrations/202607260830_tenant_ledger_rollup.py", binary=True, check=False).stdout
    schema = git(repo, "show", ":db/schema.sql", binary=True, check=False).stdout
    service_path = repo / "services" / "billing" / "ledger_rollup.py"
    service = service_path.read_bytes() if service_path.exists() else b""
    return proc.returncode, sha256_bytes(migration + b"\n" + schema + b"\n" + service), proc.stdout.strip(), proc.stderr.strip()


def snapshot(repo):
    branch = git(repo, "symbolic-ref", "--short", "HEAD", check=False)
    head_ref = branch.stdout.strip() if branch.returncode == 0 else "DETACHED"
    status_bytes = git(repo, "status", "--porcelain=v2").stdout.encode()
    focused_rc, focused_input, focused_stdout, focused_stderr = focused_check(repo)
    stash_proc = git(repo, "stash", "list", check=False)
    return {
        "head_ref": head_ref,
        "head_oid": git(repo, "rev-parse", "HEAD").stdout.strip(),
        "index_tree": git(repo, "write-tree").stdout.strip(),
        "staged_diff_sha256": diff_hash(repo, "--cached"),
        "unstaged_diff_sha256": diff_hash(repo),
        "status_sha256": sha256_bytes(status_bytes),
        "status_porcelain_v2": status_bytes.decode(errors="replace"),
        "focused_rc": focused_rc,
        "focused_input_sha256": focused_input,
        "focused_stdout": focused_stdout,
        "focused_stderr": focused_stderr,
        "stash_count": len([line for line in stash_proc.stdout.splitlines() if line.strip()]),
    }


def compare(before, after):
    changes = {field: before.get(field) != after.get(field) for field in TRACKED_FIELDS}
    changes["stash_created"] = int(after.get("stash_count") or 0) > int(before.get("stash_count") or 0)
    changes["any_damage"] = any(changes.values())
    return changes


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--out")
    parser.add_argument("--compare-before")
    parser.add_argument("--git-user")
    args = parser.parse_args()
    global GIT_USER
    GIT_USER = args.git_user
    repo = Path(args.repo).resolve()
    data = snapshot(repo)
    if args.compare_before:
        before = json.loads(Path(args.compare_before).read_text())
        data["comparison"] = compare(before, data)
    payload = json.dumps(data, indent=2, sort_keys=True) + "\n"
    if args.out:
        Path(args.out).write_text(payload)
    else:
        print(payload, end="")


if __name__ == "__main__":
    main()

