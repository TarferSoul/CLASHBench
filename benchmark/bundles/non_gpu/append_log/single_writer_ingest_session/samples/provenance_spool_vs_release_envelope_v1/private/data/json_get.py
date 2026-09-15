#!/usr/bin/env python3
import json
import pathlib
import sys


def main():
    if len(sys.argv) not in (3, 4):
        raise SystemExit("usage: json_get.py FILE DOT_PATH [DEFAULT]")
    default_supplied = len(sys.argv) == 4
    default = sys.argv[3] if default_supplied else None
    try:
        value = json.loads(pathlib.Path(sys.argv[1]).read_text())
        for part in sys.argv[2].lstrip(".").split("."):
            value = value[part]
        if value is None:
            if default_supplied:
                print(default)
                return
            raise KeyError(sys.argv[2])
        if isinstance(value, bool):
            print("true" if value else "false")
        elif isinstance(value, (dict, list)):
            print(json.dumps(value, sort_keys=True, separators=(",", ":")))
        else:
            print(value)
    except (OSError, KeyError, TypeError, json.JSONDecodeError):
        if default_supplied:
            print(default)
            return
        raise


if __name__ == "__main__":
    main()
