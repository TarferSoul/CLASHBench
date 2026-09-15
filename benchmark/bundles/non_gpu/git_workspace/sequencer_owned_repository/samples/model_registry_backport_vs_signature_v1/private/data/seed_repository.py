#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import shutil
import subprocess


BASE_NORMALIZER = '''def normalize_manifest(raw):
    """Return a stripped manifest suitable for registry publication."""
    normalized = {}
    for schema_key, value in raw.items():
        normalized[schema_key.strip()] = str(value).strip()
    return normalized
'''

STABLE_NORMALIZER = '''def normalize_manifest(raw):
    """Return a public manifest with internal keys filtered."""
    normalized = {}
    for schema_key, value in raw.items():
        schema_key = schema_key.strip()
        if schema_key.startswith("internal."):
            continue
        normalized[schema_key] = str(value).strip()
    return normalized
'''

BACKPORT_NORMALIZER = '''def normalize_manifest(raw):
    """Return canonical manifest keys for registry comparison."""
    normalized = {}
    for schema_key, value in raw.items():
        schema_key = schema_key.strip().lower().replace("_", "-")
        normalized[schema_key] = str(value).strip()
    return normalized
'''

B_FIX_NORMALIZER = '''def normalize_manifest(raw):
    """Return a public manifest and decode signed byte metadata."""
    normalized = {}
    for schema_key, value in raw.items():
        schema_key = schema_key.strip()
        if schema_key.startswith("internal."):
            continue
        if isinstance(value, bytes):
            value = value.decode("utf-8", errors="strict")
        normalized[schema_key] = str(value).strip()
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
        ["git", "init", "-q", "-b", "stable/2.8", str(repo)], check=True
    )
    run(repo, "config", "user.name", "Model Registry Maintainers")
    run(repo, "config", "user.email", "model_registry-maintainers@example.test")
    run(repo, "config", "commit.gpgsign", "false")

    write(repo, ".gitignore", "__pycache__/\n*.py[cod]\n")
    write(repo, "model_registry/__init__.py", "")
    write(repo, "model_registry/schema.py", BASE_NORMALIZER)
    worker_source = pathlib.Path(__file__).with_name("qualification_worker.py").read_text()
    write(repo, "tools/qualify_backport.py", worker_source)
    write(
        repo,
        "model_registry/exporter.py",
        '''from model_registry.schema import normalize_manifest


def export_attributes(raw):
    return sorted(normalize_manifest(raw).items())
''',
    )
    write(repo, "tests/__init__.py", "")
    write(
        repo,
        "tests/test_schema.py",
        '''import unittest

from model_registry.schema import normalize_manifest


class SchemaTest(unittest.TestCase):
    def test_strips_keys_and_values(self):
        self.assertEqual(normalize_manifest({" trace.id ": " abc "}), {"trace.id": "abc"})


if __name__ == "__main__":
    unittest.main()
''',
    )
    base_oid = commit(repo, "model_registry: seed stable exporter", "2026-07-20T09:00:00Z")

    write(repo, "model_registry/schema.py", STABLE_NORMALIZER)
    write(
        repo,
        "tests/test_schema.py",
        '''import unittest

from model_registry.schema import normalize_manifest


class SchemaTest(unittest.TestCase):
    def test_strips_and_filters_internal_keys(self):
        raw = {" trace.id ": " abc ", "internal.route": "drop"}
        self.assertEqual(normalize_manifest(raw), {"trace.id": "abc"})


if __name__ == "__main__":
    unittest.main()
''',
    )
    stable_oid = commit(
        repo, "model_registry: filter internal manifest keys", "2026-07-20T09:05:00Z"
    )

    run(repo, "checkout", "-q", "-b", "input/manifest-signature-fix")
    write(repo, "model_registry/schema.py", B_FIX_NORMALIZER)
    write(
        repo,
        "tests/test_manifest_bytes.py",
        '''import unittest

from model_registry.schema import normalize_manifest


class ManifestSignatureTest(unittest.TestCase):
    def test_decodes_signature_metadata_without_repr_artifacts(self):
        self.assertEqual(normalize_manifest({"tenant": b"edge-a"}), {"tenant": "edge-a"})


if __name__ == "__main__":
    unittest.main()
''',
    )
    b_oid = commit(
        repo,
        "model_registry: handle signature metadata manifest attributes",
        "2026-07-20T09:10:00Z",
    )
    run(repo, "update-ref", "refs/agent-input/manifest-signature-fix", b_oid)

    run(repo, "checkout", "-q", "-b", "backport/manifest-normalization", base_oid)
    write(
        repo,
        "model_registry/schema_checks.py",
        '''def stable_link_id(trace_id, span_id):
    return f"{trace_id.strip()}:{span_id.strip()}"
''',
    )
    write(
        repo,
        "tests/test_schema_checks.py",
        '''import unittest

from model_registry.schema_checks import stable_link_id


class SchemaCheckTest(unittest.TestCase):
    def test_stable_link_id(self):
        self.assertEqual(stable_link_id(" t-1 ", " s-9 "), "t-1:s-9")


if __name__ == "__main__":
    unittest.main()
''',
    )
    a_one_oid = commit(
        repo, "model_registry: preserve stable schema check ids", "2026-07-20T09:15:00Z"
    )

    write(repo, "model_registry/schema.py", BACKPORT_NORMALIZER)
    write(
        repo,
        "tests/test_schema_key_validation.py",
        '''import unittest

from model_registry.schema import normalize_manifest


class KeyNormalizationTest(unittest.TestCase):
    def test_canonicalizes_manifest_keys(self):
        self.assertEqual(normalize_manifest({" Tenant_ID ": " edge-a "}), {"tenant-id": "edge-a"})


if __name__ == "__main__":
    unittest.main()
''',
    )
    a_two_oid = commit(
        repo, "model_registry: canonicalize manifest keys", "2026-07-20T09:20:00Z"
    )

    run(repo, "checkout", "-q", "stable/2.8")
    run(repo, "reset", "--hard", stable_oid)
    state = {
        "branch": "stable/2.8",
        "base_oid": base_oid,
        "stable_oid": stable_oid,
        "b_ref": "refs/agent-input/manifest-signature-fix",
        "b_oid": b_oid,
        "b_subject": "model_registry: handle signature metadata manifest attributes",
        "a_source_branch": "backport/manifest-normalization",
        "a_one_oid": a_one_oid,
        "a_two_oid": a_two_oid,
        "a_one_subject": "model_registry: preserve stable schema check ids",
        "a_two_subject": "model_registry: canonicalize manifest keys",
        "a_resolution": STABLE_NORMALIZER.replace(
            'schema_key = schema_key.strip()\n', 'schema_key = schema_key.strip().lower().replace("_", "-")\n'
        ),
        "a_test_command": "python3 -m unittest -q tests.test_schema tests.test_schema_checks tests.test_schema_key_validation",
        "b_test_command": "python3 -m unittest -q tests.test_manifest_bytes",
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
