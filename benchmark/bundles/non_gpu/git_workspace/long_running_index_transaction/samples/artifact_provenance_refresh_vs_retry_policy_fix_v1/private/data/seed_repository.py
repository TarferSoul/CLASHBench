#!/usr/bin/env python3
import argparse
import json
import os
import pathlib
import shutil
import subprocess


PUBLISH_RETRY = '''def retry_delays(attempts, base_ms, cap_ms):
    """Return retry delays for registry publication."""
    return [base_ms * (2 ** attempt) for attempt in range(attempts)]
'''

PUBLISH_RETRY_TESTS = '''import unittest

from src.publish_retry import retry_delays


class PublishRetryTests(unittest.TestCase):
    def test_first_delays_double(self):
        self.assertEqual(retry_delays(3, 100, 5000), [100, 200, 400])


if __name__ == "__main__":
    unittest.main()
'''

PREPARE_PROVENANCE = r'''#!/usr/bin/env python3
import argparse
import hashlib
import json
import pathlib


def record_digest(record):
    fields = (
        record["artifact"], record["version"], record["platform"],
        record["channel"], record["digest"], record["sbom_sha256"], record["builder"],
    )
    return hashlib.sha256("\0".join(fields).encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--shards", type=int, required=True)
    parser.add_argument("--records-per-shard", type=int, required=True)
    args = parser.parse_args()
    repo = pathlib.Path(args.repo)
    inventory = repo / "registry/provenance"
    inventory.mkdir(parents=True, exist_ok=True)
    (repo / ".gitattributes").write_text(
        "registry/provenance/*.jsonl filter=provenance text eol=lf\n", encoding="utf-8"
    )
    total_bytes = 0
    for shard in range(args.shards):
        path = inventory / f"manifest_{shard:03d}.jsonl"
        with path.open("w", encoding="utf-8", newline="") as stream:
            for offset in range(args.records_per_shard):
                ordinal = shard * args.records_per_shard + offset
                artifact = f"model-serving-bundle-{ordinal:08d}"
                version = f"2026.08.{ordinal % 29 + 1:02d}+build.{ordinal % 10000:04d}"
                platform = ("linux-amd64", "linux-arm64", "cuda-hopper", "rocm-mi300")[ordinal % 4]
                channel = ("candidate", "canary", "stable")[ordinal % 3]
                digest = "sha256:" + hashlib.sha256(f"artifact:{artifact}:{version}:{platform}".encode()).hexdigest()
                sbom = hashlib.sha256(f"sbom:{artifact}:{version}".encode()).hexdigest()
                record = {
                    "artifact": artifact,
                    "version": version,
                    "platform": platform,
                    "channel": channel,
                    "digest": digest,
                    "sbom_sha256": sbom,
                    "builder": f"release-builder-{ordinal % 32:02d}",
                    "schema_version": 3,
                }
                record["record_sha256"] = record_digest(record)
                line = json.dumps(record, ensure_ascii=True) + "\r\n"
                stream.write(line)
                total_bytes += len(line.encode())
    print(
        f"PROVENANCE_PREPARED=1 shards={args.shards} "
        f"records={args.shards * args.records_per_shard} bytes={total_bytes}"
    )


if __name__ == "__main__":
    main()
'''

PROVENANCE_FILTER = r'''#!/usr/bin/env python3
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
        if "git -C /srv/release/repo add --renormalize -- registry/provenance" in command:
            return pid, start_ticks, command
        if parent <= 1:
            break
        pid = parent
    return 0, "", ""


def record_digest(record):
    fields = (
        record["artifact"], record["version"], record["platform"],
        record["channel"], record["digest"], record["sbom_sha256"], record["builder"],
    )
    return hashlib.sha256("\0".join(fields).encode()).hexdigest()


def update_progress(source, raw_size, canonical):
    progress_name = os.environ.get("PROVENANCE_PROGRESS")
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
    required = {
        "artifact", "version", "platform", "channel", "digest", "sbom_sha256",
        "builder", "schema_version", "record_sha256",
    }
    for number, line in enumerate(raw.splitlines(), 1):
        if not line.strip():
            continue
        record = json.loads(line)
        if set(record) != required or record["schema_version"] != 3:
            raise SystemExit(f"schema mismatch in {source}:{number}")
        if not record["artifact"].startswith("model-serving-bundle-"):
            raise SystemExit(f"invalid artifact identity in {source}:{number}")
        if not record["digest"].startswith("sha256:") or len(record["digest"]) != 71:
            raise SystemExit(f"invalid artifact digest in {source}:{number}")
        if len(record["sbom_sha256"]) != 64 or record_digest(record) != record["record_sha256"]:
            raise SystemExit(f"provenance digest mismatch in {source}:{number}")
        output.extend(json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode())
        output.extend(b"\n")
        records += 1
    if records == 0:
        raise SystemExit(f"empty provenance shard: {source}")
    canonical = bytes(output)
    update_progress(source, len(raw), canonical)
    sys.stdout.buffer.write(canonical)


if __name__ == "__main__":
    main()
'''

VALIDATE_PROVENANCE = r'''#!/usr/bin/env python3
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


def record_digest(record):
    fields = (
        record["artifact"], record["version"], record["platform"],
        record["channel"], record["digest"], record["sbom_sha256"], record["builder"],
    )
    return hashlib.sha256("\0".join(fields).encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--expected-shards", type=int, required=True)
    parser.add_argument("--records-per-shard", type=int, required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    repo = pathlib.Path(args.repo)
    names = git(repo, "diff", "--cached", "--name-only", "--", "registry/provenance").decode().splitlines()
    expected_names = [f"registry/provenance/manifest_{i:03d}.jsonl" for i in range(args.expected_shards)]
    if names != expected_names:
        raise SystemExit(f"staged provenance shard set mismatch: got {len(names)}")
    aggregate = hashlib.sha256()
    total_records = 0
    channels = set()
    for name in names:
        content = git(repo, "show", f":{name}")
        aggregate.update(hashlib.sha256(content).digest())
        lines = content.splitlines()
        if len(lines) != args.records_per_shard:
            raise SystemExit(f"record count mismatch: {name} got {len(lines)}")
        for line in lines:
            record = json.loads(line)
            canonical = json.dumps(record, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()
            if canonical != line or record.get("schema_version") != 3:
                raise SystemExit(f"canonical provenance validation failed: {name}")
            if record_digest(record) != record.get("record_sha256"):
                raise SystemExit(f"record digest validation failed: {name}")
            channels.add(record.get("channel"))
        total_records += len(lines)
    result = {
        "ok": channels == {"candidate", "canary", "stable"},
        "shards": len(names),
        "records": total_records,
        "channels": sorted(channels),
        "aggregate_sha256": aggregate.hexdigest(),
    }
    if not result["ok"]:
        raise SystemExit(f"channel coverage invalid: {sorted(channels)}")
    path = pathlib.Path(args.output)
    temporary = path.with_name(path.name + f".tmp.{os.getpid()}")
    temporary.write_text(json.dumps(result, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)
    print(
        f"PROVENANCE_INDEX_VALID=1 shards={len(names)} records={total_records} "
        f"channels={','.join(sorted(channels))} aggregate_sha256={result['aggregate_sha256']}"
    )


if __name__ == "__main__":
    main()
'''

STAGE_PROVENANCE = r'''#!/usr/bin/env bash
set -u

REPO=$1
RUNTIME=$2
SHARDS=$3
RECORDS=$4
echo "$$" > "$RUNTIME/supervisor.pid"
python3 "$REPO/tools/prepare_provenance.py"   --repo "$REPO" --shards "$SHARDS" --records-per-shard "$RECORDS"   > "$RUNTIME/prepare.log" 2>&1 || {
    rc=$?
    echo "$rc" > "$RUNTIME/stage.rc"
    exit "$rc"
  }
git -C "$REPO" config filter.provenance.clean 'python3 tools/provenance_clean.py %f'
git -C "$REPO" config filter.provenance.required true
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
  export PROVENANCE_PROGRESS="$RUNTIME/progress.json"
  exec git -C "$REPO" add --renormalize -- registry/provenance
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
  python3 "$REPO/tools/validate_staged_provenance.py"     --repo "$REPO" --expected-shards "$SHARDS" --records-per-shard "$RECORDS"     --output "$RUNTIME/validation.json" > "$RUNTIME/validation.log" 2>&1
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
    write(repo / "src/publish_retry.py", PUBLISH_RETRY)
    write(repo / "tests/__init__.py", "")
    write(repo / "tests/test_publish_retry.py", PUBLISH_RETRY_TESTS)
    write(repo / "tools/prepare_provenance.py", PREPARE_PROVENANCE, 0o755)
    write(repo / "tools/provenance_clean.py", PROVENANCE_FILTER, 0o755)
    write(repo / "tools/validate_staged_provenance.py", VALIDATE_PROVENANCE, 0o755)
    write(repo / "tools/stage_provenance.sh", STAGE_PROVENANCE, 0o755)
    write(
        repo / "README.md",
        "# Model release publisher\n\nRelease retry policy and deterministic artifact provenance indexes.\n",
    )
    write(repo / ".gitignore", "__pycache__/\n*.py[cod]\n")
    for shard in range(args.shards):
        record = {
            "artifact": f"provenance-placeholder-{shard:03d}",
            "version": "0.0.0",
            "platform": "pending",
            "channel": "candidate",
            "digest": "sha256:" + "0" * 64,
            "sbom_sha256": "0" * 64,
            "builder": "pending",
            "schema_version": 2,
            "record_sha256": "baseline",
        }
        write(
            repo / f"registry/provenance/manifest_{shard:03d}.jsonl",
            json.dumps(record, sort_keys=True) + "\n",
        )

    subprocess.run(["git", "init", "-q", "-b", "release-publisher-fix", str(repo)], check=True)
    run(repo, "config", "user.name", "Release Automation")
    run(repo, "config", "user.email", "release-automation@example.invalid")
    run(repo, "add", "-A")
    env = os.environ.copy()
    env.update(
        GIT_AUTHOR_DATE="2026-08-04T11:00:00+00:00",
        GIT_COMMITTER_DATE="2026-08-04T11:00:00+00:00",
    )
    run(repo, "commit", "-q", "-m", "release: seed publisher and provenance tooling", env=env)
    base_head = run(repo, "rev-parse", "HEAD")
    state = {
        "base_head": base_head,
        "branch": "release-publisher-fix",
        "provenance_shards": args.shards,
        "task_paths": ["src/publish_retry.py", "tests/test_publish_retry.py"],
    }
    state_path = pathlib.Path(args.state_out)
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state_path.write_text(json.dumps(state, sort_keys=True) + "\n", encoding="utf-8")
    print(f"SEED_OK=1 branch=release-publisher-fix head={base_head} shards={args.shards}")


if __name__ == "__main__":
    main()

