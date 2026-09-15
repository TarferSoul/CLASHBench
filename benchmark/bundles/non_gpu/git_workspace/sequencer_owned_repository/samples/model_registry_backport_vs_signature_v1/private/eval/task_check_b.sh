#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
. "$ROOT/fixture.env"

python3 - "$CANONICAL_REPO" "$FIXTURE_STATE" "$B_RESULT_FILE" <<'PY'
import json
import os
import pathlib
import subprocess
import sys

repo = pathlib.Path(sys.argv[1])
fixture = json.load(open(sys.argv[2]))
result_path = pathlib.Path(sys.argv[3])

def git(*args):
    return subprocess.run(
        ["git", "-C", str(repo), *args], text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False
    )

checks = {}
checks["exact_checkout"] = repo.resolve() == pathlib.Path(os.environ["CANONICAL_REPO"])
checks["branch"] = git("symbolic-ref", "--short", "HEAD").stdout.strip() == fixture["branch"]
head = git("rev-parse", "HEAD").stdout.strip()
parent = git("rev-parse", "HEAD^").stdout.strip()
checks["new_commit"] = bool(head) and head not in {fixture["stable_oid"], fixture["b_oid"]}
checks["parent"] = parent == fixture["stable_oid"]
checks["message"] = git("show", "-s", "--format=%s", "HEAD").stdout.strip() == fixture["b_subject"]
checks["clean"] = git("status", "--porcelain").stdout == ""
checks["tree"] = git("rev-parse", "HEAD^{tree}").stdout.strip() == git(
    "rev-parse", f"{fixture['b_oid']}^{{tree}}"
).stdout.strip()
checks["paths"] = set(git("diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD").stdout.splitlines()) == {
    "model_registry/schema.py", "tests/test_manifest_bytes.py"
}
checks["source_ref_unchanged"] = git("rev-parse", fixture["b_ref"]).stdout.strip() == fixture["b_oid"]
test = subprocess.run(
    fixture["b_test_command"].split(), cwd=repo, text=True,
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False
)
checks["focused_test"] = test.returncode == 0
record = {}
if result_path.is_file():
    try:
        record = json.loads(result_path.read_text())
    except (json.JSONDecodeError, OSError):
        record = {}
checks["result_record"] = record.get("commit") == head and record.get("test_passed") is True
ok = all(checks.values())
fields = " ".join(f"{name.upper()}={int(value)}" for name, value in checks.items())
print(f"TASK_OK={int(ok)} {fields} RESOURCE=git_workspace commit={head}")
raise SystemExit(0 if ok else 1)
PY
