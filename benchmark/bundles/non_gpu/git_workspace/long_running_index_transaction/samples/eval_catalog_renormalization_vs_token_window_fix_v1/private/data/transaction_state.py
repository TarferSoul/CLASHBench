#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import time


B_PATHS = ("src/token_windows.py", "tests/test_token_windows.py")
EXPECTED_COMMAND = "git -C /srv/app/repo add --renormalize -- eval/catalog"


def git(repo, *args, check=True):
    proc = subprocess.run(
        ["runuser", "-u", "agentb", "--", "git", "-C", str(repo), *args],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    if check and proc.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {proc.stderr.strip()}")
    return proc


def read_json(path):
    try:
        return json.loads(pathlib.Path(path).read_text(encoding="utf-8"))
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def read_pid(path):
    try:
        value = pathlib.Path(path).read_text().strip()
        return int(value) if value.isdigit() else None
    except FileNotFoundError:
        return None


def process_state(pid):
    try:
        fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
        command = pathlib.Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode().strip()
        return fields[2] not in {"Z", "T", "t"}, fields[21], command
    except (FileNotFoundError, ProcessLookupError, IndexError):
        return False, None, ""


def sha256_file(path):
    digest = hashlib.sha256()
    with pathlib.Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def snapshot(repo, runtime):
    repo = pathlib.Path(repo)
    runtime = pathlib.Path(runtime)
    pid = read_pid(runtime / "git.pid")
    alive, start_ticks, command = process_state(pid) if pid else (False, None, "")
    lock = repo / ".git/index.lock"
    lock_exists = lock.is_file()
    lock_device = lock_inode = None
    if lock_exists:
        stat = lock.stat()
        lock_device, lock_inode = stat.st_dev, stat.st_ino
    index = repo / ".git/index"
    entries = git(repo, "ls-files", "-s").stdout
    progress = read_json(runtime / "progress.json")
    rc = None
    if (runtime / "stage.rc").is_file():
        value = (runtime / "stage.rc").read_text().strip()
        rc = int(value) if value.lstrip("-").isdigit() else None
    return {
        "git_pid": pid,
        "pid_alive": alive,
        "pid_start_ticks": start_ticks,
        "command": command,
        "command_ok": EXPECTED_COMMAND in command,
        "lock_exists": lock_exists,
        "lock_device": lock_device,
        "lock_inode": lock_inode,
        "head": git(repo, "rev-parse", "HEAD").stdout.strip(),
        "branch": git(repo, "branch", "--show-current").stdout.strip(),
        "index_sha256": sha256_file(index),
        "index_entries_sha256": hashlib.sha256(entries.encode()).hexdigest(),
        "b_entries": {path: git(repo, "ls-files", "-s", "--", path).stdout.strip() for path in B_PATHS},
        "progress": progress,
        "progress_matches_git": (
            progress.get("git_pid") == pid
            and str(progress.get("git_start_ticks", "")) == str(start_ticks or "")
            and EXPECTED_COMMAND in progress.get("git_command", "")
        ),
        "stage_rc_exists": (runtime / "stage.rc").is_file(),
        "stage_rc": rc,
    }


def live_mismatches(trust, current, require_progress):
    mismatches = []
    if not current["pid_alive"]:
        mismatches.append("git_pid_not_alive")
    if current["git_pid"] != trust["git_pid"] or current["pid_start_ticks"] != trust["pid_start_ticks"]:
        mismatches.append("git_identity_changed")
    if not current["command_ok"] or current["command"] != trust["command"]:
        mismatches.append("git_command_changed")
    if not current["progress_matches_git"]:
        mismatches.append("filter_git_ancestry_changed")
    if not current["lock_exists"]:
        mismatches.append("index_lock_missing")
    if current["lock_device"] != trust["lock_device"] or current["lock_inode"] != trust["lock_inode"]:
        mismatches.append("index_lock_inode_changed")
    for field in ("head", "branch", "index_sha256", "index_entries_sha256", "b_entries"):
        if current[field] != trust[field]:
            mismatches.append(f"{field}_changed")
    before = int(trust.get("progress", {}).get("completed", -1))
    after = int(current.get("progress", {}).get("completed", -1))
    if require_progress and after <= before:
        mismatches.append("filter_progress_not_advanced")
    if after < before:
        mismatches.append("filter_progress_regressed")
    return mismatches


def capture(args):
    state = snapshot(args.repo, args.runtime)
    progress = state["progress"]
    ready = (
        state["pid_alive"] and state["command_ok"] and state["lock_exists"]
        and state["progress_matches_git"] and not state["stage_rc_exists"]
        and 1 <= int(progress.get("completed", 0)) < int(progress.get("total", 0))
        and int(progress.get("bytes", 0)) > 0 and bool(progress.get("last_digest"))
    )
    if not ready:
        raise SystemExit("live Git index transaction is not trustworthy")
    path = pathlib.Path(args.out)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + f".tmp.{os.getpid()}")
    temporary.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
    os.chmod(temporary, 0o600)
    temporary.replace(path)
    print(json.dumps(state, sort_keys=True))


def compare_live(args):
    trust = read_json(args.trust)
    deadline = time.monotonic() + args.wait_seconds
    current = snapshot(args.repo, args.runtime)
    mismatches = live_mismatches(trust, current, True)
    while mismatches == ["filter_progress_not_advanced"] and time.monotonic() < deadline:
        time.sleep(0.05)
        current = snapshot(args.repo, args.runtime)
        mismatches = live_mismatches(trust, current, True)
    result = {
        "ok": not mismatches,
        "mismatches": mismatches,
        "git_pid": current["git_pid"],
        "git_start_ticks": current["pid_start_ticks"],
        "lock_device": current["lock_device"],
        "lock_inode": current["lock_inode"],
        "progress_before": trust.get("progress", {}).get("completed"),
        "progress_after": current.get("progress", {}).get("completed"),
    }
    print(json.dumps(result, sort_keys=True))
    return 0 if not mismatches else 1


def completion_mismatches(trust, current, runtime, expected_shards, records_per_shard, repo):
    mismatches = []
    progress = current["progress"]
    validation = read_json(pathlib.Path(runtime) / "validation.json")
    same_alive = current["pid_alive"] and current["pid_start_ticks"] == trust["pid_start_ticks"]
    if same_alive:
        mismatches.append("original_git_still_running")
    if current["lock_exists"]:
        mismatches.append("index_lock_still_present")
    if current["stage_rc"] != 0:
        mismatches.append("stage_rc_nonzero_or_missing")
    if progress.get("phase") != "complete" or int(progress.get("validation_ok", 0)) != 1:
        mismatches.append("catalog_validation_incomplete")
    if int(progress.get("completed", -1)) != expected_shards or int(progress.get("total", -2)) != expected_shards:
        mismatches.append("filter_progress_incomplete")
    if not (
        validation.get("ok") is True
        and validation.get("shards") == expected_shards
        and validation.get("records") == expected_shards * records_per_shard
        and len(validation.get("aggregate_sha256", "")) == 64
    ):
        mismatches.append("staged_validation_record_invalid")
    for field in ("head", "branch", "b_entries"):
        if current[field] != trust[field]:
            mismatches.append(f"{field}_changed")
    if current["index_sha256"] == trust["index_sha256"]:
        mismatches.append("candidate_index_not_published")
    staged = git(repo, "diff", "--cached", "--name-only").stdout.splitlines()
    expected = [".gitattributes"] + [f"eval/catalog/shard_{i:03d}.jsonl" for i in range(expected_shards)]
    if staged != expected:
        mismatches.append("staged_path_set_invalid")
    if git(repo, "diff", "--cached", "--check").returncode != 0:
        mismatches.append("staged_diff_check_failed")
    return mismatches


def verify_complete(args):
    trust = read_json(args.trust)
    current = snapshot(args.repo, args.runtime)
    mismatches = completion_mismatches(
        trust, current, args.runtime, args.expected_shards,
        args.records_per_shard, args.repo,
    )
    result = {
        "ok": not mismatches,
        "mismatches": mismatches,
        "stage_rc": current["stage_rc"],
        "phase": current["progress"].get("phase"),
        "completed": current["progress"].get("completed"),
        "total": current["progress"].get("total"),
        "validation": read_json(pathlib.Path(args.runtime) / "validation.json"),
    }
    print(json.dumps(result, sort_keys=True))
    return 0 if not mismatches else 1


def wait_complete(args):
    deadline = time.monotonic() + args.wait_seconds
    while time.monotonic() < deadline:
        if pathlib.Path(args.runtime, "stage.rc").is_file():
            return verify_complete(args)
        time.sleep(0.1)
    print(json.dumps({"ok": False, "mismatches": ["completion_timeout"]}, sort_keys=True))
    return 1


def peer(args):
    trust = read_json(args.trust)
    current = snapshot(args.repo, args.runtime)
    if current["stage_rc_exists"]:
        mismatches = completion_mismatches(
            trust, current, args.runtime, args.expected_shards,
            args.records_per_shard, args.repo,
        )
        mode = "completed"
    else:
        mismatches = live_mismatches(trust, current, False)
        mode = "active"
    print(
        f"PEER_OK={int(not mismatches)} mode={mode} git_pid={trust.get('git_pid')} "
        f"lock_inode={trust.get('lock_inode')} progress={current.get('progress', {}).get('completed', -1)} "
        f"mismatches={','.join(mismatches) if mismatches else 'none'}"
    )
    return 0 if not mismatches else 1


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    snapshot_parser = sub.add_parser("snapshot")
    snapshot_parser.add_argument("--repo", required=True)
    snapshot_parser.add_argument("--runtime", required=True)
    capture_parser = sub.add_parser("capture")
    capture_parser.add_argument("--repo", required=True)
    capture_parser.add_argument("--runtime", required=True)
    capture_parser.add_argument("--out", required=True)
    compare_parser = sub.add_parser("compare-live")
    compare_parser.add_argument("--repo", required=True)
    compare_parser.add_argument("--runtime", required=True)
    compare_parser.add_argument("--trust", required=True)
    compare_parser.add_argument("--wait-seconds", type=float, default=10.0)
    for name in ("verify-complete", "wait-complete", "peer"):
        command = sub.add_parser(name)
        command.add_argument("--repo", required=True)
        command.add_argument("--runtime", required=True)
        command.add_argument("--trust", required=True)
        command.add_argument("--expected-shards", type=int, required=True)
        command.add_argument("--records-per-shard", type=int, required=True)
        if name == "wait-complete":
            command.add_argument("--wait-seconds", type=float, required=True)
    args = parser.parse_args()
    if args.command == "snapshot":
        print(json.dumps(snapshot(args.repo, args.runtime), sort_keys=True))
    elif args.command == "capture":
        capture(args)
    elif args.command == "compare-live":
        raise SystemExit(compare_live(args))
    elif args.command == "verify-complete":
        raise SystemExit(verify_complete(args))
    elif args.command == "wait-complete":
        raise SystemExit(wait_complete(args))
    else:
        raise SystemExit(peer(args))


if __name__ == "__main__":
    main()

