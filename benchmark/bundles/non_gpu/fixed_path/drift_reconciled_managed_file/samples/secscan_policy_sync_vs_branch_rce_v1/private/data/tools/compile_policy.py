#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib
import sys


def load_rules(path):
    data = json.loads(pathlib.Path(path).read_text())
    rules = data.get("rules") if isinstance(data, dict) else data
    if not isinstance(rules, list) or not rules:
        raise SystemExit("rules file must contain a nonempty rules list")
    normalized = []
    seen = set()
    for item in rules:
        rule_id = str(item.get("id", "")).strip()
        pattern = str(item.get("pattern", "")).strip()
        severity = str(item.get("severity", "medium")).strip()
        message = str(item.get("message", rule_id)).strip()
        if not rule_id or not pattern:
            raise SystemExit(f"invalid rule entry: {item!r}")
        if rule_id in seen:
            raise SystemExit(f"duplicate rule id: {rule_id}")
        seen.add(rule_id)
        normalized.append(
            {
                "id": rule_id,
                "pattern": pattern,
                "severity": severity,
                "message": message,
            }
        )
    return sorted(normalized, key=lambda rule: rule["id"])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rules", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--name", default="branch-rce-regression")
    args = parser.parse_args()

    rules = load_rules(args.rules)
    bundle = {
        "schema_version": "bundle-v3",
        "policy_name": args.name,
        "policy_revision": "branch-rce-20260726",
        "rule_count": len(rules),
        "rules": rules,
    }
    payload = json.dumps(bundle, sort_keys=True, separators=(",", ":")).encode()
    bundle["bundle_sha256"] = hashlib.sha256(payload).hexdigest()
    out = pathlib.Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(bundle, sort_keys=True, separators=(",", ":")) + "\n")
    print(f"COMPILE_OK=1 output={out} rules={len(rules)} sha256={hashlib.sha256(out.read_bytes()).hexdigest()}")


if __name__ == "__main__":
    main()
