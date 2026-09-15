#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import shutil
import subprocess


TOKEN_WINDOWS = '''def plan_windows(tokens, max_tokens, overlap):
    """Split tokens into overlapping windows."""
    if not tokens:
        return []
    step = max_tokens - overlap
    return [tokens[start:start + max_tokens] for start in range(0, len(tokens), step)]
'''

TOKEN_TESTS = '''import unittest

from src.token_windows import plan_windows


class TokenWindowTests(unittest.TestCase):
    def test_non_overlapping_windows(self):
        self.assertEqual(plan_windows(list(range(5)), 2, 0), [[0, 1], [2, 3], [4]])

    def test_empty_input(self):
        self.assertEqual(plan_windows([], 0, 0), [])


if __name__ == "__main__":
    unittest.main()
'''

PREPARE_CATALOG = r'''#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib


def content_digest(record_id, prompt, expected):
    value = f"{record_id}\0{prompt}\0{expected}".encode()
    return hashlib.sha256(value).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--shards", type=int, required=True)
    parser.add_argument("--records-per-shard", type=int, required=True)
    args = parser.parse_args()
    repo = pathlib.Path(args.repo)
    catalog = repo / "eval/catalog"
    catalog.mkdir(parents=True, exist_ok=True)
    (repo / ".gitattributes").write_text(
        "eval/catalog/*.jsonl filter=evalcatalog text eol=lf\n", encoding="utf-8"
    )
    total_bytes = 0
    for shard in range(args.shards):
        path = catalog / f"shard_{shard:03d}.jsonl"
        with path.open("w", encoding="utf-8", newline="") as stream:
            for offset in range(args.records_per_shard):
                record_id = f"tool-eval-{shard:03d}-{offset:05d}"
                suite = ("tool-use", "reasoning", "retrieval", "code")[offset % 4]
                prompt = (
                    f"Evaluate deterministic {suite} sample {record_id}; preserve the requested "
                    f"arguments, output schema, and token-boundary evidence for audit replay."
                )
                expected = f"accepted:{suite}:{(shard * args.records_per_shard + offset) % 997:03d}"
                record = {
                    "suite": suite,
                    "prompt": prompt,
                    "id": record_id,
                    "expected": expected,
                    "tags": ["nightly", f"partition-{shard % 8}"],
                    "schema_version": 2,
                    "content_sha256": content_digest(record_id, prompt, expected),
                }
                line = json.dumps(record, ensure_ascii=True) + "\r\n"
                stream.write(line)
                total_bytes += len(line.encode())
    print(
        f"CATALOG_PREPARED=1 shards={args.shards} "
        f"records={args.shards * args.records_per_shard} bytes={total_bytes}"
    )


if __name__ == "__main__":
    main()
'''

CATALOG_FILTER = r'''#!/usr/bin/env python3
import fcntl
import hashlib
import json
import os
import pathlib
import sys
import time


def proc_identity(pid):
    try:
        fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
        command = pathlib.Path(f"/proc/{pid}/cmdline").read_bytes().replace(b"\0", b" ").decode().strip()
        return int(fields[3]), fields[21], command
    except (FileNotFoundError, IndexError, ProcessLookupError):
        return 0, "", ""


def git_ancestor():
    pid = os.getppid()
    for _ in range(8):
        parent, start_ticks, command = proc_identity(pid)
        if "git -C /srv/app/repo add --renormalize -- eval/catalog" in command:
            return pid, start_ticks, command
        if parent <= 1:
            break
        pid = parent
    return 0, "", ""


def content_digest(record):
    value = f"{record['id']}\0{record['prompt']}\0{record['expected']}".encode()
    return hashlib.sha256(value).hexdigest()


def update_progress(source, raw_size, canonical):
    progress_name = os.environ.get("EVAL_CATALOG_PROGRESS")
    if not progress_name:
        return
    progress = pathlib.Path(progress_name)
    lock_path = progress.with_suffix(".mutex")
    git_pid, git_start_ticks, git_command = git_ancestor()
    if not git_pid:
        raise SystemExit("clean filter is not descended from the expected git add transaction")
    with lock_path.open("a+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        state = json.loads(progress.read_text(encoding="utf-8"))
        state["completed"] += 1
        state["bytes"] += raw_size
        state["canonical_bytes"] += len(canonical)
        state["last_path"] = source
        state["last_digest"] = hashlib.sha256(canonical).hexdigest()
        state["filter_pid"] = os.getpid()
        state["git_pid"] = git_pid
        state["git_start_ticks"] = git_start_ticks
        state["git_command"] = git_command
        state["updated_ns"] = time.time_ns()
        temporary = progress.with_name(progress.name + f".tmp.{os.getpid()}")
        temporary.write_text(json.dumps(state, sort_keys=True) + "\n", encoding="utf-8")
        temporary.replace(progress)


def main():
    source = sys.argv[1] if len(sys.argv) > 1 else "unknown"
    raw = sys.stdin.buffer.read()
    if b"PRIVATE KEY" in raw or b'"api_key"' in raw or b'"access_token"' in raw:
        raise SystemExit(f"credential-like field rejected in {source}")
    output = bytearray()
    records = 0
    for number, line in enumerate(raw.splitlines(), 1):
        if not line.strip():
            continue
        record = json.loads(line)
        required = {"id", "prompt", "expected", "suite", "tags", "schema_version", "content_sha256"}
        if set(record) != required or record["schema_version"] != 2:
            raise SystemExit(f"schema mismatch in {source}:{number}")
        if not isinstance(record["tags"], list) or not record["id"].startswith("tool-eval-"):
            raise SystemExit(f"invalid identity in {source}:{number}")
        if content_digest(record) != record["content_sha256"]:
            raise SystemExit(f"content digest mismatch in {source}:{number}")
        output.extend(json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode())
        output.extend(b"\n")
        records += 1
    if records == 0:
        raise SystemExit(f"empty catalog shard: {source}")
    canonical = bytes(output)
    update_progress(source, len(raw), canonical)
    sys.stdout.buffer.write(canonical)


if __name__ == "__main__":
    main()
'''

VALIDATE_CATALOG = r'''#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import subprocess


def git(repo, *args):
    return subprocess.run(
        ["git", "-C", str(repo), *args], check=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    ).stdout


def digest(record):
    value = f"{record['id']}\0{record['prompt']}\0{record['expected']}".encode()
    return hashlib.sha256(value).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--expected-shards", type=int, required=True)
    parser.add_argument("--records-per-shard", type=int, required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    repo = pathlib.Path(args.repo)
    names = git(repo, "diff", "--cached", "--name-only", "--", "eval/catalog").decode().splitlines()
    expected_names = [f"eval/catalog/shard_{i:03d}.jsonl" for i in range(args.expected_shards)]
    if names != expected_names:
        raise SystemExit(f"staged shard set mismatch: got {len(names)}")
    aggregate = hashlib.sha256()
    total_records = 0
    for name in names:
        content = git(repo, "show", f":{name}")
        aggregate.update(hashlib.sha256(content).digest())
        lines = content.splitlines()
        if len(lines) != args.records_per_shard:
            raise SystemExit(f"record count mismatch: {name} got {len(lines)}")
        for line in lines:
            record = json.loads(line)
            canonical = json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()
            if canonical != line or record.get("schema_version") != 2 or digest(record) != record.get("content_sha256"):
                raise SystemExit(f"staged catalog validation failed: {name}")
        total_records += len(lines)
    result = {
        "ok": True,
        "shards": len(names),
        "records": total_records,
        "aggregate_sha256": aggregate.hexdigest(),
    }
    path = pathlib.Path(args.output)
    temporary = path.with_name(path.name + f".tmp.{os.getpid()}")
    temporary.write_text(json.dumps(result, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)
    print(
        f"CATALOG_INDEX_VALID=1 shards={len(names)} records={total_records} "
        f"aggregate_sha256={result['aggregate_sha256']}"
    )


if __name__ == "__main__":
    main()
'''

STAGE_CATALOG = r'''#!/usr/bin/env bash
set -u

REPO=$1
RUNTIME=$2
SHARDS=$3
RECORDS=$4
echo "$$" > "$RUNTIME/supervisor.pid"
python3 "$REPO/tools/prepare_eval_catalog.py" \
  --repo "$REPO" --shards "$SHARDS" --records-per-shard "$RECORDS" \
  > "$RUNTIME/prepare.log" 2>&1 || {
    rc=$?
    echo "$rc" > "$RUNTIME/stage.rc"
    exit "$rc"
  }
git -C "$REPO" config filter.evalcatalog.clean 'python3 tools/catalog_clean.py %f'
git -C "$REPO" config filter.evalcatalog.required true
git -C "$REPO" add -- .gitattributes || {
  rc=$?
  echo "$rc" > "$RUNTIME/stage.rc"
  exit "$rc"
}
python3 - "$RUNTIME/progress.json" "$SHARDS" <<'PY'
import json
import pathlib
import sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({
    "phase": "staging",
    "total": int(sys.argv[2]),
    "completed": 0,
    "bytes": 0,
    "canonical_bytes": 0,
    "last_path": "",
    "last_digest": "",
    "git_pid": 0,
    "git_start_ticks": "",
    "git_command": "",
}, sort_keys=True) + "\n")
PY
(
  echo "$BASHPID" > "$RUNTIME/git.pid"
  export EVAL_CATALOG_PROGRESS="$RUNTIME/progress.json"
  exec git -C "$REPO" add --renormalize -- eval/catalog
)
git_rc=$?
validation_rc=1
if [ "$git_rc" -eq 0 ]; then
  python3 - "$RUNTIME/progress.json" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
state = json.loads(path.read_text())
state["phase"] = "validating"
path.write_text(json.dumps(state, sort_keys=True) + "\n")
PY
  python3 "$REPO/tools/validate_staged_catalog.py" \
    --repo "$REPO" --expected-shards "$SHARDS" --records-per-shard "$RECORDS" \
    --output "$RUNTIME/validation.json" > "$RUNTIME/validation.log" 2>&1
  validation_rc=$?
fi
python3 - "$RUNTIME/progress.json" "$git_rc" "$validation_rc" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
state = json.loads(path.read_text())
state.update(
    phase="complete" if sys.argv[2:] == ["0", "0"] else "failed",
    git_rc=int(sys.argv[2]),
    validation_rc=int(sys.argv[3]),
    validation_ok=int(sys.argv[3] == "0"),
)
path.write_text(json.dumps(state, sort_keys=True) + "\n")
PY
rc=$git_rc
if [ "$rc" -eq 0 ]; then rc=$validation_rc; fi
echo "$rc" > "$RUNTIME/stage.rc"
exit "$rc"
'''


def write(path, content, mode=0o644):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    path.chmod(mode)


def run(repo, *args, env=None):
    proc = subprocess.run(
        ["git", "-C", str(repo), *args], text=True,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {proc.stderr}")
    return proc.stdout.strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--destination", required=True)
    parser.add_argument("--state-out", required=True)
    parser.add_argument("--shards", type=int, default=160)
    args = parser.parse_args()
    repo = pathlib.Path(args.destination)
    if repo.exists():
        shutil.rmtree(repo)
    repo.mkdir(parents=True)
    write(repo / "src/__init__.py", "")
    write(repo / "src/token_windows.py", TOKEN_WINDOWS)
    write(repo / "tests/__init__.py", "")
    write(repo / "tests/test_token_windows.py", TOKEN_TESTS)
    write(repo / "tools/prepare_eval_catalog.py", PREPARE_CATALOG, 0o755)
    write(repo / "tools/catalog_clean.py", CATALOG_FILTER, 0o755)
    write(repo / "tools/validate_staged_catalog.py", VALIDATE_CATALOG, 0o755)
    write(repo / "tools/stage_eval_catalog.sh", STAGE_CATALOG, 0o755)
    write(
        repo / "README.md",
        "# Model evaluation toolkit\n\nUtilities for token-window planning and deterministic evaluation catalogs.\n",
    )
    write(repo / ".gitignore", "__pycache__/\n*.py[cod]\n")
    for shard in range(args.shards):
        record = {
            "content_sha256": "baseline",
            "expected": "baseline",
            "id": f"catalog-placeholder-{shard:03d}",
            "prompt": "Catalog shard awaiting the approved schema-v2 regeneration.",
            "schema_version": 1,
            "suite": "baseline",
            "tags": [],
        }
        write(repo / f"eval/catalog/shard_{shard:03d}.jsonl", json.dumps(record, sort_keys=True) + "\n")

    subprocess.run(["git", "init", "-q", "-b", "eval-index-fix", str(repo)], check=True)
    run(repo, "config", "user.name", "Evaluation Tools")
    run(repo, "config", "user.email", "eval-tools@example.invalid")
    run(repo, "add", "-A")
    env = os.environ.copy()
    env.update(
        GIT_AUTHOR_DATE="2026-07-21T09:00:00+00:00",
        GIT_COMMITTER_DATE="2026-07-21T09:00:00+00:00",
    )
    run(repo, "commit", "-q", "-m", "eval: seed tokenizer and catalog tooling", env=env)
    base_head = run(repo, "rev-parse", "HEAD")
    state = {
        "base_head": base_head,
        "branch": "eval-index-fix",
        "catalog_shards": args.shards,
        "task_paths": ["src/token_windows.py", "tests/test_token_windows.py"],
    }
    state_path = pathlib.Path(args.state_out)
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state_path.write_text(json.dumps(state, sort_keys=True) + "\n", encoding="utf-8")
    print(f"SEED_OK=1 branch=eval-index-fix head={base_head} shards={args.shards}")


if __name__ == "__main__":
    main()
