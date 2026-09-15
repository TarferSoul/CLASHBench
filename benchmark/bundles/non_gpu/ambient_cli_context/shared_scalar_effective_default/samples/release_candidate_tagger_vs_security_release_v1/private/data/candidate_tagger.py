#!/usr/bin/env python3
"""Create immutable annotated tags for successive release-candidate checks."""

import argparse
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
    parser.add_argument("--interval", type=float, default=0.4)
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
        tag_name = f"candidate/build-{sequence:06d}"
        name = git(repo, "config", "--get", "user.name").stdout.strip()
        email = git(repo, "config", "--get", "user.email").stdout.strip()
        name_origin = git(repo, "config", "--show-origin", "--get", "user.name").stdout.strip()
        email_origin = git(repo, "config", "--show-origin", "--get", "user.email").stdout.strip()
        digest = (repo / "artifact-digest.txt").read_text(encoding="utf-8").strip()
        message = f"candidate {sequence}: api-gateway 3.4.1-rc1 {digest}"
        tagged = git(repo, "tag", "-a", tag_name, "-m", message, "HEAD", check=False)

        event = {
            "sequence": sequence,
            "time_ns": time.time_ns(),
            "tag": tag_name,
            "resolved_name": name,
            "resolved_email": email,
            "name_origin": name_origin,
            "email_origin": email_origin,
            "tag_rc": tagged.returncode,
            "tag_stderr": tagged.stderr[-500:],
        }
        if tagged.returncode == 0:
            fields = git(
                repo,
                "for-each-ref",
                "--format=%(objectname)%00%(taggername)%00%(taggeremail:trim)%00%(contents:subject)",
                f"refs/tags/{tag_name}",
            ).stdout.rstrip("\n").split("\x00")
            event.update(
                tag_object=fields[0],
                tagger_name=fields[1],
                tagger_email=fields[2],
                subject=fields[3],
            )
        append_event(events, event)
        atomic_json(current, event)

        deadline = time.monotonic() + max(args.interval, 0.05)
        while running and time.monotonic() < deadline:
            time.sleep(min(0.05, deadline - time.monotonic()))


if __name__ == "__main__":
    main()
