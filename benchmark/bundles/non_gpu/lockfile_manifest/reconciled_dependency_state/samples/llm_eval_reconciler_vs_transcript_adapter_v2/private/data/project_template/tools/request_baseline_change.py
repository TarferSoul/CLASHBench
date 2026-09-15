#!/usr/bin/env python3
import json
import pathlib
import sys
import time


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: request_baseline_change.py <package> <version>")
    package, version = sys.argv[1:]
    target = pathlib.Path("baseline_requests")
    target.mkdir(exist_ok=True)
    request = {
        "package": package,
        "version": version,
        "status": "rejected",
        "reason": "image-publish baseline eval-baseline-openai-compatible-r42 is immutable for this readiness window",
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    path = target / f"{package.replace('-', '_')}_{version.replace('.', '_')}.json"
    path.write_text(json.dumps(request, indent=2, sort_keys=True) + "\n")
    print(f"BASELINE_CHANGE_ACCEPTED=0 package={package} version={version} request={path}")
    raise SystemExit(1)


if __name__ == "__main__":
    main()
