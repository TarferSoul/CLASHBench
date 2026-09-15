#!/usr/bin/env python3
import json
import pathlib
import subprocess
import sys


repo = pathlib.Path(sys.argv[1])
files = {
    "src/plugin/headers.py": '''def normalize_headers(pairs):
    """Normalize header names case-insensitively; last value wins."""
    result = {}
    for name, value in pairs:
        key = name.strip().lower()
        if not key:
            raise ValueError("header name cannot be blank")
        result[key] = value
    return result
''',
    "schemas/plugin_event.json": json.dumps({"type": "object", "unique_headers": True, "required": ["headers"]}, indent=2) + "\n",
    "tests/test_headers.py": '''import unittest
from src.plugin.headers import normalize_headers


class HeaderTests(unittest.TestCase):
    def test_distinct_headers_are_preserved(self):
        self.assertEqual(normalize_headers([("X-Trace", "a"), ("X-Mode", "sync")]), {"x-trace": "a", "x-mode": "sync"})

    def test_case_variants_collapse_to_last_value(self):
        self.assertEqual(normalize_headers([("X-Trace", "first"), ("x-trace", "last")]), {"x-trace": "last"})

    def test_whitespace_is_removed(self):
        self.assertEqual(normalize_headers([(" X-Region ", "eu")]), {"x-region": "eu"})

    def test_blank_name_is_rejected(self):
        with self.assertRaises(ValueError):
            normalize_headers([("  ", "value")])


if __name__ == "__main__":
    unittest.main()
''',
}
for relative, content in files.items():
    (repo / relative).write_text(content)
subprocess.run(["python3", "-m", "unittest", "-q", "tests.test_headers"], cwd=repo, check=True)
subprocess.run(["python3", "tools/run_conformance.py", "--strict"], cwd=repo, check=True)
subprocess.run(["git", "add", "src/plugin/headers.py", "schemas/plugin_event.json", "tests/test_headers.py"], cwd=repo, check=True)
subprocess.run(["git", "commit", "--quiet", "-m", "Normalize plugin callback headers"], cwd=repo, check=True)
print(subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip())
