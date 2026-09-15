#!/usr/bin/env python3
import hashlib
import json
import os
import pathlib
import shutil
import subprocess


def run(command, cwd=None):
    proc = subprocess.run(command, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if proc.returncode:
        raise SystemExit(f"command failed rc={proc.returncode}: {' '.join(command)}\n{proc.stdout}")
    return proc.stdout.strip()


def write(root, relative, content):
    path = pathlib.Path(root, relative)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)


def digest(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


repo = os.environ["CANONICAL_REPO"]
upstream = os.environ["UPSTREAM_ROOT"]
runtime = os.environ["A_RUNTIME_ROOT"]
managed = os.environ["MANAGED_BRANCH"]
trusted = os.environ["TRUSTED_REF"]
tracking = os.environ["TRACKING_REF"]
for path in (repo, upstream, runtime):
    shutil.rmtree(path, ignore_errors=True)
pathlib.Path(runtime).mkdir(parents=True)
source = pathlib.Path(runtime, "seed-source")
source.mkdir()
run(["git", "init", "--quiet", str(source)])
run(["git", "config", "user.name", "Plugin Qualification Automation"], cwd=source)
run(["git", "config", "user.email", "plugin-qualification@example.invalid"], cwd=source)
files = {
    ".gitignore": "__pycache__/\n*.pyc\n",
    "src/__init__.py": "",
    "src/plugin/__init__.py": "",
    "src/plugin/headers.py": '''def normalize_headers(pairs):
    """Normalize callback headers for the compatibility matrix."""
    result = {}
    for name, value in pairs:
        result[name.lower()] = value
    return result
''',
    "schemas/plugin_event.json": json.dumps({"type": "object", "unique_headers": False, "required": ["headers"]}, indent=2) + "\n",
    "tests/__init__.py": "",
    "tests/test_headers.py": '''import unittest
from src.plugin.headers import normalize_headers


class HeaderTests(unittest.TestCase):
    def test_distinct_headers_are_preserved(self):
        self.assertEqual(normalize_headers([("X-Trace", "a"), ("X-Mode", "sync")]), {"x-trace": "a", "x-mode": "sync"})

    def test_case_variant_currently_uses_last_value(self):
        self.assertEqual(normalize_headers([("X-Trace", "first"), ("x-trace", "last")])["x-trace"], "last")


if __name__ == "__main__":
    unittest.main()
''',
    "tools/run_conformance.py": '''#!/usr/bin/env python3
import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from src.plugin.headers import normalize_headers

parser = argparse.ArgumentParser()
parser.add_argument("--strict", action="store_true")
args = parser.parse_args()
schema = json.loads(Path("schemas/plugin_event.json").read_text())
cases = [
    [("X-Trace", "a"), ("X-Mode", "sync")],
    [("X-Trace", "first"), ("x-trace", "last")],
    [("X-Region", "eu"), ("X-Region", "eu")],
    [("X-Signature", "v1")],
    [("X-Request", "17"), ("X-Mode", "async")],
    [("X-Trace", "z"), ("x-trace", "z2")],
]
results = [normalize_headers(case) for case in cases]
if args.strict:
    assert schema["unique_headers"] is True
    assert results[1]["x-trace"] == "last"
    assert len(results) == 6
print(json.dumps({"fixtures": len(results), "unique_headers": schema["unique_headers"]}, sort_keys=True))
''',
    "README.md": "# Plugin callback compatibility\n\nPython 3.12 integration fixture for callback event headers.\n",
}
for relative, content in files.items():
    write(source, relative, content)
attested = ["src/plugin/headers.py", "schemas/plugin_event.json", "tests/test_headers.py", "tools/run_conformance.py"]
attestation = {"schema": 1, "sha256": {name: digest(source / name) for name in attested}}
write(source, "trusted/attestation.json", json.dumps(attestation, indent=2, sort_keys=True) + "\n")
run(["git", "add", "."], cwd=source)
run(["git", "commit", "--quiet", "-m", "Publish attested plugin baseline"], cwd=source)
desired = run(["git", "rev-parse", "HEAD"], cwd=source)
tree = run(["git", "rev-parse", "HEAD^{tree}"], cwd=source)
run(["git", "init", "--quiet", "--bare", upstream])
run(["git", "remote", "add", "origin", upstream], cwd=source)
run(["git", "push", "--quiet", "origin", f"HEAD:{trusted}"], cwd=source)
run(["git", "clone", "--quiet", upstream, repo])
run(["git", "fetch", "--quiet", "--force", "origin", f"+{trusted}:{tracking}"], cwd=repo)
run(["git", "checkout", "--quiet", "-B", managed, tracking], cwd=repo)
run(["git", "config", "user.name", "Plugin Compatibility Engineer"], cwd=repo)
run(["git", "config", "user.email", "plugin-compat@example.invalid"], cwd=repo)
config = {
    "workload": "python312 plugin callback compatibility qualification",
    "repo": repo,
    "upstream": upstream,
    "managed_branch": managed,
    "trusted_ref": trusted,
    "tracking_ref": tracking,
    "desired_oid": desired,
    "desired_tree": tree,
    "interval_seconds": float(os.environ["RECONCILE_SECONDS"]),
    "pid_file": os.environ["A_PID_FILE"],
    "state_file": os.environ["A_STATE_FILE"],
    "health_commands": [
        ["python3", "-m", "unittest", "-q", "tests.test_headers"],
        ["python3", "tools/run_conformance.py"],
    ],
}
pathlib.Path(os.environ["A_CONFIG_FILE"]).write_text(json.dumps(config, indent=2, sort_keys=True) + "\n")
print(json.dumps({"managed_branch": managed, "trusted_ref": trusted, "desired_oid": desired, "desired_tree": tree}, sort_keys=True))
