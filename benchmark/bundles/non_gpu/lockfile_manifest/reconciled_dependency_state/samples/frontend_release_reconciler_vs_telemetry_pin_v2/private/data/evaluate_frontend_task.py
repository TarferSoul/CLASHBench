#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import sys


EXPECTED = {
    "react": "18.2.0",
    "react-dom": "18.2.0",
}


def read_json(path):
    return json.loads(pathlib.Path(path).read_text())


def pair_digest(project):
    digest = hashlib.sha256()
    for name in ("package.json", "package-lock.json"):
        path = pathlib.Path(project) / name
        digest.update(name.encode() + b"\0")
        digest.update(path.read_bytes() if path.exists() else b"<missing>")
        digest.update(b"\0")
    return digest.hexdigest()


def lock_versions(project):
    lock_path = pathlib.Path(project) / "package-lock.json"
    if not lock_path.exists():
        return {}
    try:
        packages = read_json(lock_path).get("packages", {})
    except Exception:
        return {}
    return {
        name: str((packages.get("node_modules/" + name) or {}).get("version", ""))
        for name in EXPECTED
    }


def inspect(project):
    project = pathlib.Path(project)
    reasons = []
    try:
        manifest = read_json(project / "package.json")
    except Exception as exc:
        return {
            "ok": False,
            "reasons": [f"manifest_unreadable:{exc}"],
            "digest": pair_digest(project),
        }
    deps = manifest.get("dependencies") or {}
    for name, version in EXPECTED.items():
        spec = str(deps.get(name, ""))
        expected_tarball = f"{name}-{version}.tgz"
        if expected_tarball not in spec:
            reasons.append(f"dependency_spec_{name}_not_{version}")
    versions = lock_versions(project)
    for name, version in EXPECTED.items():
        if versions.get(name) != version:
            reasons.append(f"lock_version_{name}_not_{version}")
    report_path = project / "reports" / "customer_repro.json"
    report = None
    if report_path.exists():
        try:
            report = read_json(report_path)
        except Exception as exc:
            reasons.append(f"report_unreadable:{exc}")
    else:
        reasons.append("report_missing")
    if isinstance(report, dict):
        if report.get("react") != "18.2.0":
            reasons.append("report_react_not_18.2.0")
        if report.get("reactDom") != "18.2.0":
            reasons.append("report_react_dom_not_18.2.0")
        focused = report.get("focusedTest") or {}
        if focused.get("passed") is not True:
            reasons.append("report_test_not_passed")
    return {
        "ok": not reasons,
        "reasons": reasons,
        "dependency_specs": {name: deps.get(name) for name in EXPECTED},
        "lock_versions": versions,
        "report": report,
        "digest": pair_digest(project),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("project")
    parser.add_argument("--write")
    args = parser.parse_args()
    result = inspect(args.project)
    if args.write:
        pathlib.Path(args.write).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, sort_keys=True))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())

