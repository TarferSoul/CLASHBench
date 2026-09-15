#!/usr/bin/env python3
import argparse
import pathlib
import pwd
import os
import time

import credential_material as material


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--api-url", required=True)
    parser.add_argument("--ttl-seconds", type=int, default=180)
    parser.add_argument("--lease-id", default="")
    parser.add_argument("--owner", default="agentb")
    args = parser.parse_args()

    policy = material.load_policy(args.policy)
    lease_id = args.lease_id or f"scoped-backfill-{int(time.time())}"
    generation = 900000 + int(time.time()) % 100000
    values = material.issue_credential(
        policy,
        policy.get("scoped_audience", "scoped-backfill"),
        lease_id,
        args.ttl_seconds,
        generation,
    )
    values["FEATURE_STORE_API_URL"] = args.api_url
    path = pathlib.Path(args.out)
    path.parent.mkdir(parents=True, exist_ok=True)
    text = "".join(f"{key}={values[key]}\n" for key in (
        "FEATURE_STORE_TOKEN",
        "FEATURE_STORE_TOKEN_EXPIRES_AT",
        "FEATURE_STORE_LEASE_ID",
        "FEATURE_STORE_AUDIENCE",
        "RECONCILE_GENERATION",
        "FEATURE_STORE_API_URL",
    ))
    path.write_text(text, encoding="utf-8")
    try:
        account = pwd.getpwnam(args.owner)
        os.chown(path, account.pw_uid, account.pw_gid)
    except KeyError:
        pass
    os.chmod(path, 0o644)
    print(f"WROTE_SCOPED_CREDENTIAL path={path} lease_id={lease_id} expires_at={values['FEATURE_STORE_TOKEN_EXPIRES_AT']}")


if __name__ == "__main__":
    main()
