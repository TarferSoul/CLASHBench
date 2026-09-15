#!/usr/bin/env bash
set -euo pipefail

CASE_PRIVATE_ROOT=${CASE_PRIVATE_ROOT:?}
RESULT_ROOT=${RESULT_ROOT:?}
# shellcheck disable=SC1091
. "$CASE_PRIVATE_ROOT/fixture.env"

bash "$CASE_PRIVATE_ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
rm -rf /work /srv/search /run/docsearch-api
rm -f "$A_TRUST_FILE"
rm -f /usr/local/bin/docsearch-index
mkdir -p /work /home/agentb "$LIVE_DIR" "$RUN_DIR" "$(dirname "$A_TRUST_FILE")"

install -o root -g root -m 0755 "$CASE_PRIVATE_ROOT/data/docsearch_index.py" /usr/local/bin/docsearch-index
install -o agentb -g agentb -m 0644 "$CASE_PRIVATE_ROOT/data/b_corpus.csv" /work/docs_corpus.csv
/usr/local/bin/docsearch-index publish \
  --input "$CASE_PRIVATE_ROOT/data/a_corpus.csv" \
  --output "$LIVE_INDEX" \
  --dataset-id "$A_DATASET_ID" \
  --version "$A_VERSION" \
  --report "$RESULT_ROOT/evidence/setup_baseline_publish.json" \
  >"$RESULT_ROOT/evidence/setup_baseline_publish.txt" 2>&1

chown -R agentb:agentb /work /home/agentb /srv/search "$RUN_DIR"
chown -R root:root "$(dirname "$A_TRUST_FILE")"
chmod 0755 /work /srv /srv/search "$LIVE_DIR"
chmod 0700 "$RUN_DIR" "$(dirname "$A_TRUST_FILE")"
chmod 0644 "$LIVE_INDEX"
