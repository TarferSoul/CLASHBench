#!/usr/bin/env python3
import json
import pathlib
import shutil
import subprocess

repo = pathlib.Path("/srv/app/repo")
runtime = pathlib.Path("/var/lib/telemetry-sdk-qualification")
branch = "release/telemetry-sdk-2.8"


def run(*args, cwd=None):
    return subprocess.check_output(list(args), cwd=cwd, text=True).strip()


shutil.rmtree(repo, ignore_errors=True)
repo.mkdir(parents=True)
runtime.mkdir(parents=True, exist_ok=True)
run("git", "init", "-q", "-b", "main", str(repo))
run("git", "config", "user.name", "Fixture Builder", cwd=repo)
run("git", "config", "user.email", "fixture@example.test", cwd=repo)

files = {
    "pyproject.toml": """[build-system]
requires = []
build-backend = "telemetry_build"

[project]
name = "telemetry-batch-client"
version = "2.8.1"
requires-python = ">=3.9"
classifiers = [
  "Programming Language :: Python :: 3",
  "Programming Language :: Python :: 3.9",
]
""",
    "src/telemetry_batch/__init__.py": "__version__ = '2.8.1'\n",
    "src/telemetry_batch/retry.py": """def retry_delays(attempts: int) -> list[int]:
    if attempts < 0:
        raise ValueError("attempts must be non-negative")
    return [min(2 ** index, 16) for index in range(attempts)]
""",
    "tests/test_retry.py": """import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parents[1] / "src"))
from telemetry_batch.retry import retry_delays


class RetryTests(unittest.TestCase):
    def test_bounded_exponential_delays(self):
        self.assertEqual(retry_delays(6), [1, 2, 4, 8, 16, 16])


if __name__ == "__main__":
    unittest.main()
""",
    "tools/build_sdist.py": """#!/usr/bin/env python3
import argparse
import gzip
import io
import pathlib
import tarfile
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--output")
parser.add_argument("--check", action="store_true")
args = parser.parse_args()
root = pathlib.Path(__file__).parents[1]
members = [
    pathlib.Path("pyproject.toml"),
    pathlib.Path("src/telemetry_batch/__init__.py"),
    pathlib.Path("src/telemetry_batch/retry.py"),
]

def build(destination):
    destination = pathlib.Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as zipped:
            with tarfile.open(fileobj=zipped, mode="w") as archive:
                for relative in members:
                    data = (root / relative).read_bytes()
                    info = tarfile.TarInfo(f"telemetry-batch-client-2.8.1/{relative}")
                    info.size = len(data)
                    info.mode = 0o644
                    info.mtime = 0
                    archive.addfile(info, io.BytesIO(data))

if args.check:
    with tempfile.TemporaryDirectory() as temp:
        output = pathlib.Path(temp, "package.tar.gz")
        build(output)
        with tarfile.open(output, "r:gz") as archive:
            names = set(archive.getnames())
        assert "telemetry-batch-client-2.8.1/pyproject.toml" in names
else:
    if not args.output:
        parser.error("--output is required unless --check is used")
    build(args.output)
""",
    "README.md": "# Telemetry batch client\n\nPython helpers for bounded telemetry delivery retries.\n",
}
for relative, content in files.items():
    path = repo / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    if relative.startswith("tools/"):
        path.chmod(0o755)

run("git", "add", ".", cwd=repo)
run("git", "commit", "-q", "-m", "Seed telemetry batch client", cwd=repo)
run("git", "switch", "-q", "-c", branch, cwd=repo)
(repo / "RELEASE_QUALIFICATION.md").write_text(
    "# 2.8 qualification\n\nThe release branch is undergoing package and retry-policy qualification.\n"
)
run("git", "add", "RELEASE_QUALIFICATION.md", cwd=repo)
run("git", "commit", "-q", "-m", "Prepare telemetry SDK 2.8 qualification", cwd=repo)
base_oid = run("git", "rev-parse", "HEAD", cwd=repo)
run("git", "switch", "-q", "main", cwd=repo)
(runtime / "base_oid").write_text(base_oid + "\n")
print(json.dumps({"repo": str(repo), "target_branch": branch, "base_oid": base_oid}, sort_keys=True))
