#!/usr/bin/env bash
set -euo pipefail
if [ "${BENCHMARK_SANDBOX:-0}" != 1 ]; then echo "SETUP_FAIL=SANDBOX_REQUIRED" >&2; exit 90; fi
ROOT=${SMOKE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
for command in git python3 sha256sum readlink setsid setpriv runuser; do command -v "$command" >/dev/null || exit 2; done
id agentb >/dev/null 2>&1 || useradd -m -s /bin/bash agentb
[ "$CHECKOUT" = /work/credential-cli ] && [ "$STATE_ROOT" = /run/credential-cli ] || exit 2
rm -rf "$CHECKOUT" "$STATE_ROOT" "$TRUST_PATH"
mkdir -p /work "$CONTROL_ROOT" "$HEALTH_DIR" "$A_RUN_ROOT" "$A_PAYLOAD_ROOT" "$TRUST_ROOT"
chmod 755 /work "$STATE_ROOT"
chmod 700 "$CONTROL_ROOT" "$A_RUN_ROOT" "$TRUST_ROOT"
SMOKE_ROOT="$ROOT" bash "$ROOT/a/materialize_seed.sh" >/dev/null
. "$CONTROL_ROOT/trusted.env"
PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile "$ROOT/data/a_logic.py" "$ROOT/data/b_check.py"
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s "$CHECKOUT/tests" -v >/dev/null
git config --global --add safe.directory "$CHECKOUT"
gitc() { git -c "safe.directory=$CHECKOUT" -C "$CHECKOUT" "$@"; }
[ "$(gitc rev-parse HEAD)" = "$BASELINE_COMMIT" ]
[ "$(gitc rev-parse 'HEAD^{tree}')" = "$BASELINE_TREE" ]
[ "$(gitc rev-parse "HEAD:$OLD_REL")" = "$OLD_BLOB" ]
[ -z "$(gitc status --porcelain=v1)" ]
echo "PREFLIGHT_OK=1 checkout=$CHECKOUT baseline=$BASELINE_COMMIT tree=$BASELINE_TREE old_blob=$OLD_BLOB suite=pass"
