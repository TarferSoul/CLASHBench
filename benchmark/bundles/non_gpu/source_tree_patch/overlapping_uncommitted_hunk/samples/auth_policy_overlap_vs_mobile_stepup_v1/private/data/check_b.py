#!/usr/bin/env python3
import importlib
import pathlib
import sys


def main() -> int:
    root = pathlib.Path(sys.argv[1]).resolve()
    sys.path.insert(0, str(root / "src"))
    policy = importlib.import_module("accessmesh.session_policy")
    action = policy.remediation_for("REFRESH_TOKEN_REPLAY")
    invalidates = policy.should_invalidate_sessions("REFRESH_TOKEN_REPLAY")
    test_path = root / "tests" / "test_mobile_session_policy.py"
    source = (root / "src" / "accessmesh" / "session_policy.py").read_text()
    ok = (
        action == "step_up"
        and invalidates is False
        and test_path.is_file()
        and '"REFRESH_TOKEN_REPLAY": "step_up"' in source
    )
    print(
        "B_BEHAVIOR_OK=%d action=%s invalidates=%s test_file=%d"
        % (1 if ok else 0, action, int(invalidates), 1 if test_path.is_file() else 0)
    )
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())

