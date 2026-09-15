#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib


def write_json(path, value):
    pathlib.Path(path).write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


def write_jsonl(path, values):
    pathlib.Path(path).write_text("".join(json.dumps(value, sort_keys=True) + "\n" for value in values))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture-dir", required=True)
    parser.add_argument("--token-file", required=True)
    parser.add_argument("--a-runtime", required=True)
    args = parser.parse_args()
    fixture_dir = pathlib.Path(args.fixture_dir)
    a_runtime = pathlib.Path(args.a_runtime)
    fixture_dir.mkdir(parents=True, exist_ok=True)
    a_runtime.mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.token_file).write_text("local-gateway-release-audit-token\n")

    routes = {
        "policy_generation": "gateway-authz-shadow-2026-08-04.3",
        "routes": [
            {"route_id": "artifacts.publish", "method": "POST", "scope": "artifact:write"},
            {"route_id": "artifacts.fetch", "method": "GET", "scope": "artifact:read"},
            {"route_id": "deployments.promote", "method": "POST", "scope": "deploy:promote"},
            {"route_id": "deployments.rollback", "method": "POST", "scope": "deploy:rollback"},
            {"route_id": "keys.rotate", "method": "POST", "scope": "keys:rotate"},
            {"route_id": "provenance.verify", "method": "POST", "scope": "attestation:verify"},
        ],
        "decision_classes": ["allow", "deny", "step_up", "upstream_error"],
    }
    write_json(a_runtime / "routes.json", routes)

    builders = ["linux-amd64", "linux-arm64", "darwin-arm64"]
    stages = ["compile", "unit-test", "package", "sign", "publish", "promotion-check"]
    rows = []
    for index in range(1, 73):
        source = f"release-source-{index:04d}"
        rows.append({
            "attestation_id": f"rel-att-{index:04d}",
            "release_id": "edge-gateway-2026.08.04-rc3",
            "builder": builders[(index - 1) % len(builders)],
            "stage": stages[(index - 1) % len(stages)],
            "artifact_digest": "sha256:" + hashlib.sha256(source.encode()).hexdigest(),
            "source_revision": hashlib.sha1(source.encode()).hexdigest(),
            "predicate_type": "https://slsa.dev/provenance/v1",
            "verified": True,
        })
    write_jsonl(fixture_dir / "release_attestations.jsonl", rows)


if __name__ == "__main__":
    main()
