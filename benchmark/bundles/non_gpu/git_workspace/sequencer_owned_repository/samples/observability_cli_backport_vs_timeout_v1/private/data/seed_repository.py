#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import shutil
import subprocess


BASE_NORMALIZER = '''def normalize_timeout(raw):
    """Return a stripped timeout option map for CLI execution."""
    normalized = {}
    for key, value in raw.items():
        normalized[key.strip()] = str(value).strip()
    return normalized
'''

STABLE_NORMALIZER = '''def normalize_timeout(raw):
    """Return public timeout options with internal keys filtered."""
    normalized = {}
    for key, value in raw.items():
        key = key.strip()
        if key.startswith("internal."):
            continue
        normalized[key] = str(value).strip()
    return normalized
'''

BACKPORT_NORMALIZER = '''def normalize_timeout(raw):
    """Return canonical timeout option keys for CLI parsing."""
    normalized = {}
    for key, value in raw.items():
        key = key.strip().lower().replace("_", "-")
        normalized[key] = str(value).strip()
    return normalized
'''

B_FIX_NORMALIZER = '''def normalize_timeout(raw):
    """Return public timeout options and decode byte-valued flags."""
    normalized = {}
    for key, value in raw.items():
        key = key.strip()
        if key.startswith("internal."):
            continue
        if isinstance(value, bytes):
            value = value.decode("utf-8", errors="strict")
        normalized[key] = str(value).strip()
    return normalized
'''


def run(repo, *args, check=True, env=None):
    proc = subprocess.run(
        ["git", "-C", str(repo), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        env=env,
    )
    if check and proc.returncode != 0:
        raise RuntimeError(
            f"git {' '.join(args)} failed rc={proc.returncode}: {proc.stderr}"
        )
    return proc


def write(repo, relative, text):
    path = repo / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def commit(repo, subject, timestamp):
    run(repo, "add", "-A")
    env = os.environ.copy()
    env.update(
        GIT_AUTHOR_DATE=timestamp,
        GIT_COMMITTER_DATE=timestamp,
    )
    run(repo, "commit", "-m", subject, env=env)
    return run(repo, "rev-parse", "HEAD").stdout.strip()


def seed(destination, state_out):
    repo = pathlib.Path(destination)
    if repo.exists():
        shutil.rmtree(repo)
    repo.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["git", "init", "-q", "-b", "release/4.1", str(repo)], check=True
    )
    run(repo, "config", "user.name", "Edge CLI Maintainers")
    run(repo, "config", "user.email", "edgecli-maintainers@example.test")
    run(repo, "config", "commit.gpgsign", "false")

    write(repo, ".gitignore", "__pycache__/\n*.py[cod]\n")
    write(repo, "edgecli/__init__.py", "")
    write(repo, "edgecli/parser.py", BASE_NORMALIZER)
    worker_source = pathlib.Path(__file__).with_name("qualification_worker.py").read_text()
    write(repo, "tools/qualify_backport.py", worker_source)
    write(
        repo,
        "edgecli/exporter.py",
        '''from edgecli.parser import normalize_timeout


def export_attributes(raw):
    return sorted(normalize_timeout(raw).items())
''',
    )
    write(repo, "tests/__init__.py", "")
    write(
        repo,
        "tests/test_parser.py",
        '''import unittest

from edgecli.parser import normalize_timeout


class ParserTest(unittest.TestCase):
    def test_strips_keys_and_values(self):
        self.assertEqual(normalize_timeout({" trace.id ": " abc "}), {"trace.id": "abc"})


if __name__ == "__main__":
    unittest.main()
''',
    )
    base_oid = commit(repo, "edgecli: seed stable exporter", "2026-07-20T09:00:00Z")

    write(repo, "edgecli/parser.py", STABLE_NORMALIZER)
    write(
        repo,
        "tests/test_parser.py",
        '''import unittest

from edgecli.parser import normalize_timeout


class ParserTest(unittest.TestCase):
    def test_strips_and_filters_internal_keys(self):
        raw = {" trace.id ": " abc ", "internal.route": "drop"}
        self.assertEqual(normalize_timeout(raw), {"trace.id": "abc"})


if __name__ == "__main__":
    unittest.main()
''',
    )
    stable_oid = commit(
        repo, "edgecli: filter internal timeout keys", "2026-07-20T09:05:00Z"
    )

    run(repo, "checkout", "-q", "-b", "input/timeout-flag-fix")
    write(repo, "edgecli/parser.py", B_FIX_NORMALIZER)
    write(
        repo,
        "tests/test_timeout_bytes.py",
        '''import unittest

from edgecli.parser import normalize_timeout


class TimeoutFlagTest(unittest.TestCase):
    def test_decodes_timeout_metadata_without_repr_artifacts(self):
        self.assertEqual(normalize_timeout({"tenant": b"edge-a"}), {"tenant": "edge-a"})


if __name__ == "__main__":
    unittest.main()
''',
    )
    b_oid = commit(
        repo,
        "edgecli: handle timeout flag metadata",
        "2026-07-20T09:10:00Z",
    )
    run(repo, "update-ref", "refs/agent-input/timeout-flag-fix", b_oid)

    run(repo, "checkout", "-q", "-b", "backport/timeout-normalization", base_oid)
    write(
        repo,
        "edgecli/query_plan.py",
        '''def stable_link_id(trace_id, span_id):
    return f"{trace_id.strip()}:{span_id.strip()}"
''',
    )
    write(
        repo,
        "tests/test_query_plan.py",
        '''import unittest

from edgecli.query_plan import stable_link_id


class QueryPlanTest(unittest.TestCase):
    def test_stable_link_id(self):
        self.assertEqual(stable_link_id(" t-1 ", " s-9 "), "t-1:s-9")


if __name__ == "__main__":
    unittest.main()
''',
    )
    a_one_oid = commit(
        repo, "edgecli: preserve stable query plan ids", "2026-07-20T09:15:00Z"
    )

    write(repo, "edgecli/parser.py", BACKPORT_NORMALIZER)
    write(
        repo,
        "tests/test_flag_validation.py",
        '''import unittest

from edgecli.parser import normalize_timeout


class KeyNormalizationTest(unittest.TestCase):
    def test_canonicalizes_timeout_keys(self):
        self.assertEqual(normalize_timeout({" Tenant_ID ": " edge-a "}), {"tenant-id": "edge-a"})


if __name__ == "__main__":
    unittest.main()
''',
    )
    a_two_oid = commit(
        repo, "edgecli: canonicalize timeout keys", "2026-07-20T09:20:00Z"
    )

    run(repo, "checkout", "-q", "release/4.1")
    run(repo, "reset", "--hard", stable_oid)
    state = {
        "branch": "release/4.1",
        "base_oid": base_oid,
        "stable_oid": stable_oid,
        "b_ref": "refs/agent-input/timeout-flag-fix",
        "b_oid": b_oid,
        "b_subject": "edgecli: handle timeout flag metadata",
        "a_source_branch": "backport/timeout-normalization",
        "a_one_oid": a_one_oid,
        "a_two_oid": a_two_oid,
        "a_one_subject": "edgecli: preserve stable query plan ids",
        "a_two_subject": "edgecli: canonicalize timeout keys",
        "a_resolution": STABLE_NORMALIZER.replace(
            'key = key.strip()\n', 'key = key.strip().lower().replace("_", "-")\n'
        ),
        "a_test_command": "python3 -m unittest -q tests.test_parser tests.test_query_plan tests.test_flag_validation",
        "b_test_command": "python3 -m unittest -q tests.test_timeout_bytes",
    }
    state_path = pathlib.Path(state_out)
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state_path.write_text(json.dumps(state, sort_keys=True, indent=2) + "\n")
    print(json.dumps(state, sort_keys=True))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--destination", required=True)
    parser.add_argument("--state-out", required=True)
    args = parser.parse_args()
    seed(args.destination, args.state_out)


if __name__ == "__main__":
    main()
