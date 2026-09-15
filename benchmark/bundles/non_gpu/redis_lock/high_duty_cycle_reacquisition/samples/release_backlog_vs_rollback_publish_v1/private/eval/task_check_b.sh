#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"

set +e
detail=$(python3 - "$B_INPUT" "$B_OUTPUT" "$ALIAS_PATH" "$B_GENERATION" "$REDIS_JOURNAL_KEY" "$LIB_ROOT" "$REDIS_HOST" "$REDIS_PORT" "$REDIS_PASSWORD_FILE" <<'PY' 2>&1
import collections,hashlib,json,pathlib,re,sys
source_path,output_path,alias_path,generation,journal_key,lib_root,host,port,password_file=sys.argv[1:]
sys.path.insert(0,lib_root)
from search_indexctl import RedisClient, canonical_json
source_raw=pathlib.Path(source_path).read_bytes(); source=json.loads(source_raw)
root=pathlib.Path(output_path); manifest=json.loads((root/"manifest.json").read_text())
documents=[json.loads(line) for line in (root/"documents.jsonl").read_text().splitlines() if line]
terms=json.loads((root/"terms.json").read_text()); alias=json.loads(pathlib.Path(alias_path).read_text())
assert manifest["schema"]=="aurora_search_generation_v1" and manifest["status"]=="complete"
assert manifest["collection"]==source["collection"]=="customer-help"
assert manifest["generation"]==generation and manifest["source_revision"]==source["source_revision"]
assert manifest["source_sha256"]==hashlib.sha256(source_raw).hexdigest()
assert manifest["document_count"]==len(source["documents"])==len(documents)==12
assert manifest["completed_batches"]==6 and manifest["lease_key"]=="release:search-api:promotion"
assert manifest["lease_ttl_ms"]==800 and manifest["renew_interval_ms"]==180
assert hashlib.sha256((root/"documents.jsonl").read_bytes()).hexdigest()==manifest["documents_sha256"]
assert hashlib.sha256((root/"terms.json").read_bytes()).hexdigest()==manifest["terms_sha256"]
assert sorted(item["id"] for item in documents)==sorted(item["id"] for item in source["documents"])
token_re=re.compile(r"[A-Za-z][A-Za-z0-9_-]{1,63}")
expected=collections.defaultdict(list)
for item in sorted(source["documents"],key=lambda row:row["id"]):
    for term in sorted(set(value.lower() for value in token_re.findall(item["title"]+" "+item["body"]))):
        expected[term].append(item["id"])
assert terms==dict(sorted(expected.items())) and manifest["term_count"]==len(terms)
assert alias["schema"]=="aurora_search_alias_v1" and alias["collection"]=="customer-help"
assert alias["generation"]==generation and pathlib.Path(alias["manifest"]).resolve()==(root/"manifest.json").resolve()
assert alias["manifest_sha256"]==hashlib.sha256((root/"manifest.json").read_bytes()).hexdigest()
redis=RedisClient(host,int(port),pathlib.Path(password_file).read_text().strip())
records=[json.loads(item) for item in (redis.command("LRANGE",journal_key,0,-1) or [])]
commits=[item for item in records if item.get("event")=="commit" and item.get("payload",{}).get("generation")==generation]
assert len(commits)>=1, "missing_guarded_commit"
commit=commits[-1]
for key in ("source_sha256","documents_sha256","terms_sha256","document_count","term_count","completed_batches"):
    assert commit["payload"][key]==manifest[key], f"guarded_commit_{key}_mismatch"
assert commit["token_sha256"]==manifest["lease_fingerprint_sha256"]
assert int(manifest["guarded_commit_journal_index"])>0
print(f"generation={generation} documents={len(documents)} terms={len(terms)} journal_index={manifest['guarded_commit_journal_index']}")
PY
)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "TASK_OK=1 $detail"
else
  reason=$(printf '%s' "$detail" | tail -n 1 | tr ' ' '_' | tr -cd '[:alnum:]_:=./-')
  echo "TASK_OK=0 reason=${reason:-validation_failed}"
  exit 1
fi
