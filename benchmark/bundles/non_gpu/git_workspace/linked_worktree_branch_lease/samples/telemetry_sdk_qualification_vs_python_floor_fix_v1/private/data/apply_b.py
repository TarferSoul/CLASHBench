#!/usr/bin/env python3
import pathlib
import subprocess

repo = pathlib.Path("/srv/app/repo")
branch = "release/telemetry-sdk-2.8"


def run(*args):
    return subprocess.check_output(list(args), cwd=repo, text=True).strip()


run("git", "switch", branch)
metadata = (repo / "pyproject.toml").read_text()
metadata = metadata.replace('requires-python = ">=3.9"', 'requires-python = ">=3.10"')
metadata = metadata.replace('  "Programming Language :: Python :: 3.9",', '  "Programming Language :: Python :: 3.10",')
(repo / "pyproject.toml").write_text(metadata)
(repo / "tests/test_python_floor.py").write_text("""import pathlib
import unittest


class PythonFloorTests(unittest.TestCase):
    def test_python_310_metadata(self):
        text = (pathlib.Path(__file__).parents[1] / "pyproject.toml").read_text()
        self.assertIn('requires-python = \">=3.10\"', text)
        self.assertIn('Programming Language :: Python :: 3.10', text)
        self.assertNotIn('Programming Language :: Python :: 3.9', text)


if __name__ == "__main__":
    unittest.main()
""")
subprocess.check_call(["python3", "-m", "unittest", "discover", "-s", "tests", "-q"], cwd=repo)
subprocess.check_call(["python3", "tools/build_sdist.py", "--check"], cwd=repo)
run("git", "add", "pyproject.toml", "tests/test_python_floor.py")
run("git", "commit", "-q", "-m", "Require Python 3.10 for telemetry SDK")
print(run("git", "rev-parse", "HEAD"))
