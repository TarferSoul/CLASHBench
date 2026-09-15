#!/usr/bin/env python3
import argparse
import json
import pathlib
import uuid

from backend_http import request


def baseline_state(lineage, serial, workspace):
    return {
        "version": 4,
        "terraform_version": "tf-compatible-consul-backend-fixture",
        "serial": serial,
        "lineage": lineage,
        "outputs": {
            "terraform_workspace": {"value": workspace, "type": "string"},
            "gateway_config_digest": {"value": "baseline-dns-v1", "type": "string"},
            "private_endpoint_rule_id": {"value": "", "type": "string"},
            "dns_output": {"value": "", "type": "string"},
            "validation_probe_passed": {"value": False, "type": "bool"},
        },
        "resources": [
            {
                "mode": "managed",
                "type": "terraform_data",
                "name": "feature_store_gateway",
                "instances": [
                    {
                        "attributes": {
                            "id": "gateway-baseline",
                            "input": {
                                "workspace": workspace,
                                "generation": "baseline",
                                "route_table": "feature-store-private-gateway",
                            },
                        }
                    }
                ],
            }
        ],
        "fixture": {
            "workspace": workspace,
            "generation": "baseline",
            "endpoint_rule": None,
            "dns_output": None,
            "probe_passed": False,
        },
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend-url", required=True)
    parser.add_argument("--state-key", required=True)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--lineage-file", required=True)
    args = parser.parse_args()
    lineage_path = pathlib.Path(args.lineage_file)
    lineage_path.parent.mkdir(parents=True, exist_ok=True)
    lineage = str(uuid.uuid4())
    lineage_path.write_text(lineage + "\n")
    state = baseline_state(lineage, 1, args.workspace)
    request(
        args.backend_url,
        "POST",
        "/v1/state/seed",
        {"key": args.state_key, "lineage": lineage, "serial": 1, "state": state},
    )
    print(json.dumps({"seeded": True, "lineage": lineage, "serial": 1}, sort_keys=True))


if __name__ == "__main__":
    main()

