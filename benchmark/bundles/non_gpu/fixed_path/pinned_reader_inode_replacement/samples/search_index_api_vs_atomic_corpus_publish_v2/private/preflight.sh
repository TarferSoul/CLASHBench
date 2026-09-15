#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
set -a
. "$PRIVATE_ROOT/fixture.env"
set +a

test -x /usr/local/bin/docsearch-index
test -f "$PRIVATE_ROOT/data/a_corpus.csv"
test -f "$PRIVATE_ROOT/data/b_corpus.csv"
test -f /work/docs_corpus.csv
test -d "$LIVE_DIR"
python3 - <<'PY'
import csv
import pathlib

for path in ("/work/docs_corpus.csv",):
    with pathlib.Path(path).open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        assert {"term", "title", "body"}.issubset(set(reader.fieldnames or []))
        assert any(row.get("term") == "gpu-quota" for row in reader)
print("PREFLIGHT_OK=1")
PY

