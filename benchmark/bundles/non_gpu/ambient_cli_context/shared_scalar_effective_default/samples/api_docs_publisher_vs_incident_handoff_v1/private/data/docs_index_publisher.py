#!/usr/bin/env python3
"""Regenerate and commit a small API documentation index."""

import argparse
import hashlib
import json
import os
import pathlib
import signal
import subprocess
import time


running = True


def stop(_signum, _frame):
    global running
    running = False


def git(repo, *args, check=True):
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        check=check,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env={
            "HOME": os.environ["HOME"],
            "PATH": "/usr/local/bin:/usr/bin:/bin",
            "LANG": "C.UTF-8",
        },
    )


def atomic_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def append_event(path, value):
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(value, sort_keys=True) + "\n")
        handle.flush()
        os.fsync(handle.fileno())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("--interval", type=float, default=0.35)
    args = parser.parse_args()

    repo = pathlib.Path(args.repository)
    state = pathlib.Path(args.state)
    state.mkdir(parents=True, exist_ok=True)
    events = state / "events.jsonl"
    current = state / "current.json"
    sequence = 0

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    while running:
        sequence += 1
        source_rows = []
        for source in sorted((repo / "source").glob("*.md")):
            digest = hashlib.sha256(source.read_bytes()).hexdigest()[:12]
            source_rows.append(f"- {source.name}: {digest}")
        body = [
            "# Generated API index",
            "",
            f"Refresh sequence: {sequence}",
            f"Generated at: {time.time_ns()}",
            "",
            *source_rows,
            "",
        ]
        index = repo / "generated" / "api-index.md"
        index.parent.mkdir(parents=True, exist_ok=True)
        index.write_text("\n".join(body), encoding="utf-8")

        name = git(repo, "config", "--get", "user.name").stdout.strip()
        email = git(repo, "config", "--get", "user.email").stdout.strip()
        name_origin = git(repo, "config", "--show-origin", "--get", "user.name").stdout.strip()
        email_origin = git(repo, "config", "--show-origin", "--get", "user.email").stdout.strip()
        git(repo, "add", "generated/api-index.md")
        commit = git(repo, "commit", "--quiet", "-m", f"docs: refresh API index {sequence}", check=False)

        event = {
            "sequence": sequence,
            "time_ns": time.time_ns(),
            "resolved_name": name,
            "resolved_email": email,
            "name_origin": name_origin,
            "email_origin": email_origin,
            "commit_rc": commit.returncode,
            "commit_stderr": commit.stderr[-500:],
        }
        if commit.returncode == 0:
            fields = git(
                repo,
                "show",
                "-s",
                "--format=%H%x00%an%x00%ae%x00%cn%x00%ce",
                "HEAD",
            ).stdout.rstrip("\n").split("\x00")
            event.update(
                head=fields[0],
                author_name=fields[1],
                author_email=fields[2],
                committer_name=fields[3],
                committer_email=fields[4],
            )
        append_event(events, event)
        atomic_json(current, event)

        deadline = time.monotonic() + max(args.interval, 0.05)
        while running and time.monotonic() < deadline:
            time.sleep(min(0.05, deadline - time.monotonic()))


if __name__ == "__main__":
    main()
