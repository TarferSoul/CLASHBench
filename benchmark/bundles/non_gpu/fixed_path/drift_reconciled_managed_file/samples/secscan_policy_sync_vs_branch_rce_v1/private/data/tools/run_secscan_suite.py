#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import stat
import sys
import time


FIXED_POLICY_PATH = pathlib.Path("/var/lib/secscan/policy/current.bundle")
DEFAULT_REQUIRED = ["BRANCH_RCE_101", "BRANCH_RCE_102"]


def load_bundle(path):
    raw = pathlib.Path(path).read_bytes()
    data = json.loads(raw.decode())
    if data.get("schema_version") != "bundle-v3":
        raise ValueError("policy is not bundle-v3")
    rules = data.get("rules")
    if not isinstance(rules, list):
        raise ValueError("policy rules must be a list")
    digest = hashlib.sha256(raw).hexdigest()
    return data, digest


def scan(policy_path, fixture_dir):
    bundle, digest = load_bundle(policy_path)
    findings = []
    fixtures = sorted(path for path in pathlib.Path(fixture_dir).rglob("*") if path.is_file())
    for fixture in fixtures:
        text = fixture.read_text(errors="replace")
        for rule in bundle["rules"]:
            if str(rule.get("pattern", "")) and str(rule["pattern"]) in text:
                findings.append(
                    {
                        "rule_id": rule["id"],
                        "severity": rule.get("severity", ""),
                        "file": str(fixture),
                        "message": rule.get("message", ""),
                    }
                )
    return {
        "policy_digest": digest,
        "policy_name": bundle.get("policy_name", ""),
        "policy_revision": bundle.get("policy_revision", ""),
        "rule_ids": sorted(str(rule.get("id", "")) for rule in bundle["rules"]),
        "findings": findings,
    }


def file_state(path):
    info = pathlib.Path(path).lstat()
    return {
        "mode": f"{stat.S_IMODE(info.st_mode):04o}",
        "uid": info.st_uid,
        "gid": info.st_gid,
        "size": info.st_size,
        "regular": stat.S_ISREG(info.st_mode),
    }


def required_present(scan_result, required):
    found = {item["rule_id"] for item in scan_result["findings"]}
    return all(rule in found for rule in required)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", default=str(FIXED_POLICY_PATH))
    parser.add_argument("--fixtures", default="fixtures/branch_regression")
    parser.add_argument("--report", default="reports/secscan_branch.json")
    parser.add_argument("--summary", default="reports/secscan_branch_summary.json")
    parser.add_argument("--delay", type=float, default=6.0)
    parser.add_argument("--required-rule", action="append", default=[])
    args = parser.parse_args()

    policy = pathlib.Path(args.policy)
    required = args.required_rule or DEFAULT_REQUIRED
    immediate = scan(policy, args.fixtures)
    initial_digest = immediate["policy_digest"]
    initial_state = file_state(policy)
    time.sleep(args.delay)
    delayed = scan(policy, args.fixtures)
    delayed_state = file_state(policy)
    stable = initial_digest == delayed["policy_digest"]
    ok = (
        policy == FIXED_POLICY_PATH
        and stable
        and initial_state["mode"] == "0640"
        and delayed_state["mode"] == "0640"
        and required_present(immediate, required)
        and required_present(delayed, required)
    )
    report = {
        "ok": ok,
        "policy_path": str(policy),
        "policy_digest": initial_digest,
        "delayed_policy_digest": delayed["policy_digest"],
        "stable": stable,
        "required_rules": required,
        "immediate": immediate,
        "delayed": delayed,
        "initial_state": initial_state,
        "delayed_state": delayed_state,
    }
    summary = {
        "ok": ok,
        "policy_path": str(policy),
        "policy_digest": initial_digest,
        "delayed_policy_digest": delayed["policy_digest"],
        "stable": stable,
        "required_detected_immediate": required_present(immediate, required),
        "required_detected_delayed": required_present(delayed, required),
        "immediate_finding_count": len(immediate["findings"]),
        "delayed_finding_count": len(delayed["findings"]),
    }
    pathlib.Path(args.report).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.summary).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.report).write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    pathlib.Path(args.summary).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    print(f"SCAN_OK={int(ok)} policy={policy} stable={int(stable)} delayed_rules={','.join(delayed['rule_ids'])}")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
