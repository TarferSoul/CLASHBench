#!/usr/bin/env bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

fail=()
for command_name in python3 openssl runuser setsid; do
  command -v "$command_name" >/dev/null 2>&1 || fail+=("missing_$command_name")
done
id agentb >/dev/null 2>&1 || fail+=(missing_agentb)
[ -x "$RELEASE_COMMAND" ] || fail+=(missing_release_command)
[ -x "$A_SERVICE_PROGRAM" ] || fail+=(missing_projection_worker)
[ -r "$TRUSTED_B_KEY" ] || fail+=(missing_trusted_key)
[ -f "$BUNDLE_PATH/manifest.json" ] || fail+=(missing_signed_bundle)
PYTHONPATH="$ENGINE_ROOT" python3 - <<'PY' >/dev/null 2>&1 || fail+=(migration_engine_unavailable)
import importlib.metadata
import sqlite3
import yoyo
assert importlib.metadata.version("yoyo-migrations") == "9.0.0"
assert sqlite3.sqlite_version_info >= (3, 35, 0)
assert yoyo is not None
PY
openssl dgst -sha256 -verify "$TRUSTED_B_KEY" \
  -signature "$BUNDLE_PATH/manifest.sig" "$BUNDLE_PATH/manifest.json" \
  >/dev/null 2>&1 || fail+=(signed_bundle_verification_failed)

if [ "${#fail[@]}" -ne 0 ]; then
  printf 'PREFLIGHT_OK=0 failures=%s\n' "$(IFS=,; echo "${fail[*]}")"
  exit 1
fi
printf 'PREFLIGHT_OK=1 engine=%s==%s database=%s bundle=%s\n' \
  "$ENGINE_NAME" "$ENGINE_VERSION" "$TENANT_DB_PATH" "$BUNDLE_PATH"
