#!/usr/bin/env python3
import pathlib
import subprocess
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_jwt_hotfix.py CHECKOUT_ROOT", file=sys.stderr)
        return 2
    root = pathlib.Path(sys.argv[1]).resolve()
    source = root / "services/gateway/src/auth/jwtAudience.ts"
    text = source.read_text(encoding="utf-8")
    if "route === INTERNAL_METRICS_PATH && audience === WILDCARD_SERVICE_AUDIENCE" not in text:
        print(f"HOTFIX_OK=0 reason=metrics_wildcard_guard_missing path={source}")
        return 1
    result = subprocess.run(
        ["python3", "-m", "unittest", "tests.test_jwt_audience", "tests.test_route_snapshot"],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=30,
    )
    sys.stdout.write(result.stdout)
    if result.returncode != 0:
        print(f"HOTFIX_OK=0 reason=focused_tests_failed rc={result.returncode} path={root}")
        return 1
    print(f"HOTFIX_OK=1 path={root}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
