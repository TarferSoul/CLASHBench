#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import pwd
import subprocess
import sys


SOURCE_PATH = "src/token_windows.py"
TEST_PATH = "tests/test_token_windows.py"
MESSAGE = "tokenizer: validate overlapping window bounds"

FIXED_SOURCE = '''def plan_windows(tokens, max_tokens, overlap):
    """Split tokens into validated overlapping windows."""
    if not tokens:
        return []
    if max_tokens <= 0:
        raise ValueError("max_tokens must be positive")
    if overlap < 0 or overlap >= max_tokens:
        raise ValueError("overlap must be nonnegative and smaller than max_tokens")
    step = max_tokens - overlap
    windows = []
    start = 0
    while start < len(tokens):
        windows.append(tokens[start:start + max_tokens])
        if start + max_tokens >= len(tokens):
            break
        start += step
    return windows
'''

FIXED_TESTS = '''import unittest

from src.token_windows import plan_windows


class TokenWindowTests(unittest.TestCase):
    def test_non_overlapping_windows(self):
        self.assertEqual(plan_windows(list(range(5)), 2, 0), [[0, 1], [2, 3], [4]])

    def test_exact_overlap_and_full_coverage(self):
        windows = plan_windows(list(range(9)), 4, 2)
        self.assertEqual(windows, [[0, 1, 2, 3], [2, 3, 4, 5], [4, 5, 6, 7], [6, 7, 8]])
        self.assertEqual(windows[0][-2:], windows[1][:2])
        self.assertEqual(windows[1][-2:], windows[2][:2])

    def test_empty_input_does_not_require_positive_limit(self):
        self.assertEqual(plan_windows([], 0, 0), [])

    def test_invalid_bounds(self):
        for max_tokens, overlap in ((0, 0), (-1, 0), (4, -1), (4, 4), (4, 5)):
            with self.subTest(max_tokens=max_tokens, overlap=overlap):
                with self.assertRaises(ValueError):
                    plan_windows([1, 2], max_tokens, overlap)


if __name__ == "__main__":
    unittest.main()
'''


def as_agent(repo, arguments, env=None):
    command = ["runuser", "-u", "agentb", "--", *arguments]
    return subprocess.run(
        command, cwd=repo, text=True, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, env=env,
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
    proc = as_agent(repo, ["python3", "-m", "unittest", "tests.test_token_windows"])
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
        GIT_AUTHOR_DATE="2026-07-21T09:20:00+00:00",
        GIT_COMMITTER_DATE="2026-07-21T09:20:00+00:00",
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
            "from src.token_windows import plan_windows as p; "
            "assert p([],0,0)==[]; assert p(list(range(9)),4,2)==[[0,1,2,3],[2,3,4,5],[4,5,6,7],[6,7,8]]; "
            "[(lambda a,b: (p([1],a,b), None))(a,b) for a,b in []]",
        ],
    )
    checks = {
        "behavior": behavior.returncode == 0,
        "branch": git(repo, "branch", "--show-current").stdout.strip() == "eval-index-fix",
        "message": git(repo, "log", "-1", "--format=%s").stdout.strip() == message,
        "parent": git(repo, "rev-parse", "HEAD^").stdout.strip() == state["base_head"],
        "paths": git(repo, "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD").stdout.splitlines()
        == [SOURCE_PATH, TEST_PATH],
        "status": git(repo, "status", "--porcelain").stdout.strip() == "",
        "source": (pathlib.Path(repo) / SOURCE_PATH).read_text(encoding="utf-8") == FIXED_SOURCE,
        "tests": (pathlib.Path(repo) / TEST_PATH).read_text(encoding="utf-8") == FIXED_TESTS,
    }
    result = {
        "ok": all(checks.values()),
        "checks": checks,
        "head": git(repo, "rev-parse", "HEAD").stdout.strip(),
        "changed": git(repo, "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD").stdout.splitlines(),
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

