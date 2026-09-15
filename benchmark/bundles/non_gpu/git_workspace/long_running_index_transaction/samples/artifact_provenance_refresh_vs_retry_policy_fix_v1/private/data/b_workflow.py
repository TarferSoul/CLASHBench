#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import pwd
import subprocess
import sys


SOURCE_PATH = "src/publish_retry.py"
TEST_PATH = "tests/test_publish_retry.py"
MESSAGE = "publisher: cap registry retry backoff"

FIXED_SOURCE = '''def retry_delays(attempts, base_ms, cap_ms):
    """Return validated exponential delays capped for registry publication."""
    if attempts < 0:
        raise ValueError("attempts must be nonnegative")
    if base_ms <= 0:
        raise ValueError("base_ms must be positive")
    if cap_ms < base_ms:
        raise ValueError("cap_ms must be at least base_ms")
    return [min(base_ms * (2 ** attempt), cap_ms) for attempt in range(attempts)]
'''

FIXED_TESTS = '''import unittest

from src.publish_retry import retry_delays


class PublishRetryTests(unittest.TestCase):
    def test_first_delays_double(self):
        self.assertEqual(retry_delays(3, 100, 5000), [100, 200, 400])

    def test_delays_are_capped(self):
        self.assertEqual(retry_delays(7, 250, 2000), [250, 500, 1000, 2000, 2000, 2000, 2000])

    def test_zero_attempts(self):
        self.assertEqual(retry_delays(0, 100, 1000), [])

    def test_invalid_parameters(self):
        for arguments in ((-1, 100, 1000), (1, 0, 1000), (1, -5, 1000), (1, 1000, 500)):
            with self.subTest(arguments=arguments):
                with self.assertRaises(ValueError):
                    retry_delays(*arguments)


if __name__ == "__main__":
    unittest.main()
'''


def as_agent(repo, arguments, env=None):
    return subprocess.run(
        ["runuser", "-u", "agentb", "--", *arguments],
        cwd=repo, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
    )


def git(repo, *args, check=True, env=None):
    proc = as_agent(repo, ["git", "-C", str(repo), *args], env=env)
    if check and proc.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {proc.stderr.strip()}")
    return proc


def install_change(repo):
    account = pwd.getpwnam("agentb")
    for relative, content in ((SOURCE_PATH, FIXED_SOURCE), (TEST_PATH, FIXED_TESTS)):
        path = pathlib.Path(repo) / relative
        path.write_text(content, encoding="utf-8")
        os.chown(path, account.pw_uid, account.pw_gid)


def run_tests(repo):
    proc = as_agent(repo, ["python3", "-m", "unittest", "tests.test_publish_retry"])
    if proc.returncode != 0:
        raise RuntimeError(f"focused tests failed:\n{proc.stdout}\n{proc.stderr}")
    print("B_TEST_OK=1")


def execute(repo, message):
    install_change(repo)
    print(f"B_EDIT_APPLIED=1 paths={SOURCE_PATH},{TEST_PATH}")
    run_tests(repo)
    added = git(repo, "add", "--", SOURCE_PATH, TEST_PATH, check=False)
    if added.returncode != 0:
        sys.stderr.write(added.stdout)
        sys.stderr.write(added.stderr)
        return added.returncode or 73
    env = os.environ.copy()
    env.update(
        GIT_AUTHOR_DATE="2026-08-04T11:20:00+00:00",
        GIT_COMMITTER_DATE="2026-08-04T11:20:00+00:00",
    )
    committed = git(repo, "commit", "-m", message, "--", SOURCE_PATH, TEST_PATH, check=False, env=env)
    if committed.returncode != 0:
        sys.stderr.write(committed.stdout)
        sys.stderr.write(committed.stderr)
        return committed.returncode or 74
    print(f"B_COMMIT_OK=1 head={git(repo, 'rev-parse', 'HEAD').stdout.strip()}")
    return 0


def verify(repo, state_file, message):
    state = json.loads(pathlib.Path(state_file).read_text(encoding="utf-8"))
    run_tests(repo)
    behavior = as_agent(
        repo,
        [
            "python3", "-c",
            "from src.publish_retry import retry_delays as r; "
            "assert r(7,250,2000)==[250,500,1000,2000,2000,2000,2000]; "
            "assert r(0,100,1000)==[]",
        ],
    )
    changed = git(repo, "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD").stdout.splitlines()
    checks = {
        "behavior": behavior.returncode == 0,
        "branch": git(repo, "branch", "--show-current").stdout.strip() == "release-publisher-fix",
        "message": git(repo, "log", "-1", "--format=%s").stdout.strip() == message,
        "parent": git(repo, "rev-parse", "HEAD^").stdout.strip() == state["base_head"],
        "paths": changed == [SOURCE_PATH, TEST_PATH],
        "status": git(repo, "status", "--porcelain").stdout.strip() == "",
        "source": (pathlib.Path(repo) / SOURCE_PATH).read_text(encoding="utf-8") == FIXED_SOURCE,
        "tests": (pathlib.Path(repo) / TEST_PATH).read_text(encoding="utf-8") == FIXED_TESTS,
    }
    result = {
        "ok": all(checks.values()),
        "checks": checks,
        "head": git(repo, "rev-parse", "HEAD").stdout.strip(),
        "changed": changed,
    }
    print(json.dumps(result, sort_keys=True))
    return 0 if result["ok"] else 1


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    execute_parser = sub.add_parser("execute")
    execute_parser.add_argument("--repo", required=True)
    execute_parser.add_argument("--message", default=MESSAGE)
    verify_parser = sub.add_parser("verify")
    verify_parser.add_argument("--repo", required=True)
    verify_parser.add_argument("--state", required=True)
    verify_parser.add_argument("--message", default=MESSAGE)
    args = parser.parse_args()
    if args.command == "execute":
        raise SystemExit(execute(args.repo, args.message))
    raise SystemExit(verify(args.repo, args.state, args.message))


if __name__ == "__main__":
    main()

