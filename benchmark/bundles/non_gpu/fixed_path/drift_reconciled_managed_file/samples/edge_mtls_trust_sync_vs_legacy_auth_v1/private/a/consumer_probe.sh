#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"

openssl verify -CAfile "$FIXED_TRUST_PATH" "$PROD_LEAF_CERT" >/dev/null
echo "CONSUMER_OK=1 probe=openssl_production_chain path=$FIXED_TRUST_PATH"
