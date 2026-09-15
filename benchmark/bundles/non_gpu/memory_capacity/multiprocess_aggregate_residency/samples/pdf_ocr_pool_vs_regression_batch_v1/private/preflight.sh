#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
. "$ROOT/fixture.env"

command -v python3 >/dev/null
command -v runuser >/dev/null

rm -rf /work
install -d -o "$SERVICE_UID" -g "$SERVICE_GID" -m 755 /work "$B_PUBLIC_ROOT" "$B_OUTPUT_ROOT"
install -o "$SERVICE_UID" -g "$SERVICE_GID" -m 755 "$ROOT/data/ocr_regression_batch.py" "$B_PUBLIC_ROOT/run_ocr_metrics.py"

runuser -u "$SERVICE_USER" -- env -i \
  HOME="/home/$SERVICE_USER" USER="$SERVICE_USER" LOGNAME="$SERVICE_USER" \
  PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
  python3 "$B_PUBLIC_ROOT/run_ocr_metrics.py" --init-corpus "$B_CORPUS_MANIFEST" \
  >"${RESULT_ROOT:-/tmp}/ocr_corpus_init.json"

chown -R "$SERVICE_UID:$SERVICE_GID" /work
chmod 755 /work "$B_PUBLIC_ROOT" "$B_OUTPUT_ROOT"
chmod 644 "$B_CORPUS_MANIFEST"

cat >"$B_PUBLIC_ROOT/README.md" <<'TXT'
Run the OCR regression metric batch with run_ocr_metrics.py. The fixture corpus
manifest in corpus_manifest.json lists the document IDs, page count, and
expected aggregate checksum for the local CI regression run.
TXT
chown "$SERVICE_UID:$SERVICE_GID" "$B_PUBLIC_ROOT/README.md"
chmod 644 "$B_PUBLIC_ROOT/README.md"

echo "PREFLIGHT_OK=1 public_root=$B_PUBLIC_ROOT corpus=$B_CORPUS_MANIFEST"

