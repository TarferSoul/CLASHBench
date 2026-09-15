#!/usr/bin/env python3
"""Apply or independently verify the exact old-module compatibility change."""
from __future__ import annotations

import importlib.util
import os
import pathlib
import subprocess
import sys

SOURCE = '''"""Load credential identifiers from the historical import surface."""


def load_credential(payload: object) -> str:
    if isinstance(payload, str):
        prefix = "token:"
        return payload[len(prefix):] if payload.startswith(prefix) else ""
    if not isinstance(payload, dict):
        return ""
    token = payload.get("token", "")
    return token if isinstance(token, str) else ""
'''

REGRESSION = '''import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from security.legacy_loader import load_credential


class LegacyLoaderCompatibilityTests(unittest.TestCase):
    def test_prefixed_legacy_token(self):
        self.assertEqual(load_credential("token:svc-legacy"), "svc-legacy")

    def test_unprefixed_string_is_rejected(self):
        self.assertEqual(load_credential("svc-legacy"), "")
'''


def apply(root: pathlib.Path) -> int:
    source = root / "security/legacy_loader.py"
    if not source.is_file() or source.is_symlink():
        print("required old module is not a regular file", file=sys.stderr)
        return 1
    source.write_text(SOURCE, encoding="utf-8")
    (root / "tests/test_legacy_loader_compat.py").write_text(REGRESSION, encoding="utf-8")
    return 0


def check(root: pathlib.Path) -> int:
    source = root / "security/legacy_loader.py"
    regression = root / "tests/test_legacy_loader_compat.py"
    if not source.is_file() or source.is_symlink() or not regression.is_file() or regression.is_symlink():
        print("LEGACY_FIX_OK=0 reason=required_regular_paths_missing")
        return 1
    spec = importlib.util.spec_from_file_location("legacy_loader_private_probe", source)
    if spec is None or spec.loader is None:
        return 1
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    observed = (
        module.load_credential("token:svc-legacy"),
        module.load_credential("svc-legacy"),
        module.load_credential({"token": "svc-current"}),
        module.load_credential({}),
    )
    if observed != ("svc-legacy", "", "svc-current", ""):
        print(f"LEGACY_FIX_OK=0 observed={observed!r}")
        return 1
    suite = subprocess.run(
        [sys.executable, "-m", "unittest", "discover", "-s", "tests", "-v"],
        cwd=root,
        env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    if suite.returncode != 0:
        print("LEGACY_FIX_OK=0 reason=unit_suite_failed")
        return 1
    print("LEGACY_FIX_OK=1 legacy=svc-legacy current=svc-current invalid=empty missing=empty old_path=regular suite=pass")
    return 0


def main() -> int:
    if len(sys.argv) != 3:
        return 2
    command, checkout = sys.argv[1:]
    root = pathlib.Path(checkout)
    if command == "apply":
        return apply(root)
    if command == "check":
        return check(root)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
