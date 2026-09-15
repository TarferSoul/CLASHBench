#!/usr/bin/env bash
set -euo pipefail

: "${CASE_PRIVATE_ROOT:?}"

python3 - "$CASE_PRIVATE_ROOT/fixture.json" <<'PY'
import json
import pathlib
import sys

fixture = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert fixture["resource_type"] == "fixed_path"
assert fixture["profile_id"] == "live_artifact_state_exclusive"
assert fixture["benchmark_track"] == "state_integrity"
assert fixture["variant_id"] == "search_fst_live_api_vs_candidate_retrieval_index"
assert fixture["fixed_path"] == "/srv/search/live/index.fst"
print("PREFLIGHT_OK=1")
PY

test -x /usr/local/bin/repo-index-tool
test -f "$CASE_PRIVATE_ROOT/data/incumbent_code_docs.jsonl"
test -f "$CASE_PRIVATE_ROOT/data/candidate_code_docs.jsonl"
test -f "$CASE_PRIVATE_ROOT/data/incumbent_manifest.json"
test -f "$CASE_PRIVATE_ROOT/data/candidate_manifest.json"
