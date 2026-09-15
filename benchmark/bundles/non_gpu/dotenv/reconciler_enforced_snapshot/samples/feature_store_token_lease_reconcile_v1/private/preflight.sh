#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?}"
# shellcheck disable=SC1090
. "$CASE_PRIVATE_ROOT/fixture.env"

test -r "$POLICY_FILE"
test -w "$(dirname "$ENV_FILE")"
test -r "$SCOPED_CREDENTIAL_FILE"
command -v feature-envctl >/dev/null
command -v feature-export >/dev/null
command -v setpriv >/dev/null
command -v setsid >/dev/null
test -x /opt/feature-store/bin/feature_api.py
test -x /opt/feature-store/bin/lease_reconciler.py
python3 - "$SCOPED_CREDENTIAL_FILE" "$SCOPED_AUDIENCE" <<'PY'
import pathlib, sys
path, audience = sys.argv[1:]
values = {}
for raw in pathlib.Path(path).read_text().splitlines():
    if raw and not raw.startswith("#") and "=" in raw:
        key, value = raw.split("=", 1)
        values[key] = value
missing = [key for key in ("FEATURE_STORE_TOKEN", "FEATURE_STORE_TOKEN_EXPIRES_AT", "FEATURE_STORE_LEASE_ID", "FEATURE_STORE_AUDIENCE") if not values.get(key)]
if missing or values.get("FEATURE_STORE_AUDIENCE") != audience:
    raise SystemExit(f"bad scoped credential missing={missing} audience={values.get('FEATURE_STORE_AUDIENCE')}")
print(f"PREFLIGHT_OK=1 scoped_lease={values.get('FEATURE_STORE_LEASE_ID')} audience={values.get('FEATURE_STORE_AUDIENCE')}")
PY
