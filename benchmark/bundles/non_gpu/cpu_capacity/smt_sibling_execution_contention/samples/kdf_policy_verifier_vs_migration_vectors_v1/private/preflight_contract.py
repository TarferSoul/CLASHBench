#!/usr/bin/env python3
import json
import pathlib
import sys

job = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert job == {
    "algorithm": "pbkdf2-hmac-sha256",
    "description": "Pinned credential KDF migration-vector acceptance for the reproducible security runner lane",
    "dklen": 32,
    "iterations": 120000,
    "job_name": "credential_kdf_migration_2026_08",
    "measurement_passes": 3,
    "placement_policy": "credential_migration_smt_lane_v4",
    "vector_count": 24,
}
a_root, b_root = pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
policy = json.loads((a_root / "policy.json").read_text())
assert policy["algorithm"] == "pbkdf2-hmac-sha256" and policy["iterations"] == 105000
assert len((a_root / "policy_vectors.jsonl").read_text().splitlines()) == 12
assert len((b_root / "migration_inputs.jsonl").read_text().splitlines()) == 24
