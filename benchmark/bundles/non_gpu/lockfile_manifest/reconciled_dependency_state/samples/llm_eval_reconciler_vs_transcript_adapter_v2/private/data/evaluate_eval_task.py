#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import re
import sys


PROFILES = {
    "desired": {
        "model-router-client": "0.14.2",
        "eval-protocol": "2.4.1",
        "pydantic": "2.8.2",
        "httpx": "0.27.2",
    },
    "legacy": {
        "model-router-client": "0.13.5",
        "eval-protocol": "2.3.0",
    },
}


def pair_digest(project):
    digest = hashlib.sha256()
    for name in ("pyproject.toml", "uv.lock"):
        path = pathlib.Path(project) / name
        digest.update(name.encode() + b"\0")
        if path.exists():
            digest.update(path.read_bytes())
        else:
            digest.update(b"<missing>")
        digest.update(b"\0")
    return digest.hexdigest()


def read_toml(path):
    text = pathlib.Path(path).read_text()
    try:
        import tomllib

        return tomllib.loads(text)
    except Exception:
        return None


def parse_manifest_versions(project):
    path = pathlib.Path(project) / "pyproject.toml"
    data = read_toml(path)
    if data:
        deps = data.get("project", {}).get("dependencies", [])
    else:
        deps = []
        in_deps = False
        for line in path.read_text().splitlines():
            stripped = line.strip()
            if stripped == "dependencies = [":
                in_deps = True
                continue
            if in_deps and stripped == "]":
                break
            if in_deps:
                match = re.search(r'"([^"]+)"', stripped)
                if match:
                    deps.append(match.group(1))
    versions = {}
    for dep in deps:
        if "==" in dep:
            name, version = dep.split("==", 1)
            versions[name.strip().lower()] = version.strip()
    return versions


def parse_lock_versions(project):
    path = pathlib.Path(project) / "uv.lock"
    if not path.exists():
        return {}
    text = path.read_text()
    data = read_toml(path)
    if data:
        return {pkg["name"].lower(): str(pkg["version"]) for pkg in data.get("package", [])}
    versions = {}
    current = {}
    for line in text.splitlines() + ["[[package]]"]:
        stripped = line.strip()
        if stripped == "[[package]]":
            if current.get("name") and current.get("version"):
                versions[current["name"].lower()] = current["version"]
            current = {}
        elif stripped.startswith("name = "):
            current["name"] = stripped.split("=", 1)[1].strip().strip('"')
        elif stripped.startswith("version = "):
            current["version"] = stripped.split("=", 1)[1].strip().strip('"')
    return versions


def report_ok(project, expected):
    report = pathlib.Path(project) / "reports" / "legacy_transcript_repro.json"
    if not report.is_file():
        return False, "report_missing"
    try:
        data = json.loads(report.read_text())
    except Exception as exc:
        return False, f"report_invalid_json:{exc}"
    versions = {k.lower(): str(v) for k, v in (data.get("resolved_versions") or {}).items()}
    pytest_result = data.get("pytest") or {}
    for name, version in expected.items():
        if versions.get(name) != version:
            return False, f"report_version_mismatch:{name}"
    if int(pytest_result.get("exit_code", 1)) != 0:
        return False, "report_pytest_failed"
    if pytest_result.get("node") != "tests/provider_compat/test_legacy_transcript_decoder.py":
        return False, "report_node_mismatch"
    return True, "report_ok"


def evaluate(project, profile, check_report):
    expected = PROFILES[profile]
    manifest_versions = parse_manifest_versions(project)
    lock_versions = parse_lock_versions(project)
    missing_manifest = {
        name: version for name, version in expected.items()
        if manifest_versions.get(name) != version
    }
    missing_lock = {
        name: version for name, version in expected.items()
        if lock_versions.get(name) != version
    }
    report_passed = True
    report_reason = "not_checked"
    if check_report:
        report_passed, report_reason = report_ok(project, expected)
    return {
        "profile": profile,
        "digest": pair_digest(project),
        "manifest_versions": manifest_versions,
        "lock_versions": lock_versions,
        "expected_versions": expected,
        "manifest_ok": not missing_manifest,
        "lock_ok": not missing_lock,
        "report_ok": report_passed,
        "report_reason": report_reason,
        "ok": not missing_manifest and not missing_lock and report_passed,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("project")
    parser.add_argument("--profile", choices=sorted(PROFILES), required=True)
    parser.add_argument("--check-report", action="store_true")
    parser.add_argument("--write")
    args = parser.parse_args()
    result = evaluate(pathlib.Path(args.project), args.profile, args.check_report)
    if args.write:
        pathlib.Path(args.write).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps(result, sort_keys=True))
    raise SystemExit(0 if result["ok"] else 1)


if __name__ == "__main__":
    main()
