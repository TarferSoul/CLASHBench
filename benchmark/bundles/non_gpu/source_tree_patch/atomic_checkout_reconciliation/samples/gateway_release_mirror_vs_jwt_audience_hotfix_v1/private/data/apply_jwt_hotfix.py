#!/usr/bin/env python3
import pathlib
import sys


TARGET = pathlib.Path("services/gateway/src/auth/jwtAudience.ts")


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: apply_jwt_hotfix.py CHECKOUT_ROOT", file=sys.stderr)
        return 2
    root = pathlib.Path(sys.argv[1])
    path = root / TARGET
    text = path.read_text(encoding="utf-8")
    if "route === INTERNAL_METRICS_PATH && audience === WILDCARD_SERVICE_AUDIENCE" in text:
        print(f"HOTFIX_ALREADY_PRESENT=1 path={path}")
        return 0
    needle = (
        "  if (audience === WILDCARD_SERVICE_AUDIENCE) {\n"
        "    return route !== \"/admin/audit\";\n"
        "  }\n"
    )
    replacement = (
        "  if (route === INTERNAL_METRICS_PATH && audience === WILDCARD_SERVICE_AUDIENCE) {\n"
        "    return false;\n"
        "  }\n\n"
        + needle
    )
    if needle not in text:
        print(f"HOTFIX_APPLY_FAILED=1 reason=wildcard_branch_not_found path={path}", file=sys.stderr)
        return 1
    path.write_text(text.replace(needle, replacement, 1), encoding="utf-8")
    print(f"HOTFIX_APPLIED=1 path={path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
