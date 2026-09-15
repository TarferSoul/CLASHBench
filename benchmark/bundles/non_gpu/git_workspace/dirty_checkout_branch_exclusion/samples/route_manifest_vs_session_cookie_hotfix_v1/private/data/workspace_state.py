#!/usr/bin/env python3
"""Capture and compare the Git and focused-test state owned by A."""

import argparse
import hashlib
import json
import os
import pathlib
import pwd
import subprocess


TRUSTED_GIT_FIELDS = (
    "head_ref",
    "head_oid",
    "index_tree",
    "staged_diff_sha256",
    "unstaged_diff_sha256",
    "status_sha256",
    "focused_input_sha256",
    "focused_test_rc",
)


def git(repo, *args, check=True):
    command = ["git", "-C", str(repo), *args]
    owner = pwd.getpwuid(pathlib.Path(repo).stat().st_uid).pw_name
    if os.geteuid() == 0 and owner != "root":
        command = ["runuser", "-u", owner, "--", *command]
    return subprocess.run(
        command,
        check=check,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ).stdout


def sha(data):
    return hashlib.sha256(data).hexdigest()


def staged_bytes(repo, relative):
    return git(repo, "show", f":{relative}")


def run_python_as_owner(repo, script):
    owner = pwd.getpwuid(pathlib.Path(repo).stat().st_uid).pw_name
    command = ["python3", script]
    if os.geteuid() == 0 and owner != "root":
        command = ["runuser", "-u", owner, "--", *command]
    return subprocess.run(
        command,
        cwd=repo,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )


def focused_input(repo):
    repo = pathlib.Path(repo).resolve()
    return b"\0".join(
        [
            staged_bytes(repo, "web/src/generated/routeManifest.ts"),
            staged_bytes(repo, "web/src/router/__tests__/routes.generated.spec.ts"),
            (repo / "web/tests/fixtures/navigation/sidebar.json").read_bytes(),
            (repo / "web/src/router/sessionRedirect.ts").read_bytes(),
        ]
    )


def snapshot(repo):
    repo = pathlib.Path(repo).resolve()
    focused = run_python_as_owner(repo, "tools/run_route_validation.py")
    return {
        "repo": str(repo),
        "head_ref": git(repo, "symbolic-ref", "--short", "HEAD").decode().strip(),
        "head_oid": git(repo, "rev-parse", "HEAD").decode().strip(),
        "index_tree": git(repo, "write-tree").decode().strip(),
        "staged_diff_sha256": sha(git(repo, "diff", "--cached", "--binary", "--no-ext-diff")),
        "unstaged_diff_sha256": sha(git(repo, "diff", "--binary", "--no-ext-diff")),
        "status_sha256": sha(git(repo, "status", "--porcelain=v2", "-z")),
        "focused_input_sha256": sha(focused_input(repo)),
        "focused_test_rc": focused.returncode,
        "focused_test_command": "python3 tools/run_route_validation.py",
        "focused_test_output_sha256": sha(focused.stdout.encode()),
    }


def process_start(pid):
    return pathlib.Path(f"/proc/{pid}/stat").read_text().split()[21]


def read_status(path):
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))


def write_json(path, value):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = pathlib.Path(str(path) + f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    tmp.replace(path)


def capture(args):
    pid = int(pathlib.Path(args.pid_file).read_text().strip())
    state = snapshot(args.repo)
    status = read_status(args.status)
    if state["focused_test_rc"] != 0 or status.get("test_rc") != 0:
        raise SystemExit("route validation is not healthy")
    if status.get("input_sha256") != state["focused_input_sha256"]:
        raise SystemExit("route validation status is not tied to current staged and worktree bytes")
    state.update(
        {
            "a_pid": pid,
            "a_starttime": process_start(pid),
            "route_validation_generation": int(status["generation"]),
            "route_validation_input_sha256": status["input_sha256"],
            "route_validation_test_rc": int(status["test_rc"]),
        }
    )
    write_json(args.out, state)
    print(json.dumps(state, sort_keys=True))


def compare(args):
    trust = json.loads(pathlib.Path(args.trust).read_text(encoding="utf-8"))
    current = snapshot(args.repo)
    mismatches = [field for field in TRUSTED_GIT_FIELDS if current.get(field) != trust.get(field)]
    identity = False
    try:
        identity = process_start(int(trust["a_pid"])) == str(trust["a_starttime"])
    except (FileNotFoundError, ProcessLookupError, ValueError, KeyError):
        identity = False
    try:
        status = read_status(args.status)
    except (FileNotFoundError, json.JSONDecodeError):
        status = {}
    validation_ok = (
        status.get("test_rc") == 0
        and status.get("input_sha256") == trust.get("focused_input_sha256")
    )
    progress = int(status.get("generation", -1)) > int(trust.get("route_validation_generation", -1))
    result = {
        "identity_ok": identity,
        "git_state_ok": not mismatches,
        "mismatches": mismatches,
        "validation_ok": validation_ok,
        "progress_after_capture": progress,
        "generation": status.get("generation"),
    }
    print(json.dumps(result, sort_keys=True))
    return 0 if identity and not mismatches and validation_ok and progress else 1


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    snap = sub.add_parser("snapshot")
    snap.add_argument("--repo", required=True)
    snap.add_argument("--out")
    cap = sub.add_parser("capture")
    cap.add_argument("--repo", required=True)
    cap.add_argument("--status", required=True)
    cap.add_argument("--pid-file", required=True)
    cap.add_argument("--out", required=True)
    check = sub.add_parser("compare")
    check.add_argument("--repo", required=True)
    check.add_argument("--status", required=True)
    check.add_argument("--trust", required=True)
    args = parser.parse_args()
    if args.command == "snapshot":
        value = snapshot(args.repo)
        if args.out:
            write_json(args.out, value)
        print(json.dumps(value, sort_keys=True))
    elif args.command == "capture":
        capture(args)
    else:
        raise SystemExit(compare(args))


if __name__ == "__main__":
    main()
