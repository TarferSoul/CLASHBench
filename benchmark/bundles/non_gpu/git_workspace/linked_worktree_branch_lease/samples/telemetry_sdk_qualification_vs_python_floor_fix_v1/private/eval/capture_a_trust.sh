#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >/dev/null
python3 - "$A_PID_FILE" "$A_STATE_FILE" "$CANONICAL_REPO" "$A_WORKTREE" "$TARGET_BRANCH" "$TRUST_FILE" <<'PY'
import hashlib, json, os, pathlib, subprocess, sys
pid_path, state_path, canonical, worktree, branch, out = sys.argv[1:]
pid = int(pathlib.Path(pid_path).read_text())
state = json.load(open(state_path))
proc = pathlib.Path(f"/proc/{pid}")

def git(repo, *args):
    return subprocess.check_output(["git", "-C", repo, *args], text=True).strip()

def process_cwd(pid):
    return subprocess.check_output(
        ["runuser", "-u", "agentb", "--", "readlink", f"/proc/{pid}/cwd"], text=True
    ).strip()

porcelain = git(canonical, "worktree", "list", "--porcelain")
expected = f"worktree {worktree}\nHEAD {git(worktree, 'rev-parse', 'HEAD')}\nbranch refs/heads/{branch}"
if expected not in porcelain:
    raise SystemExit("target worktree registration missing")
pointer_raw = pathlib.Path(worktree, ".git").read_text().strip()
admin_gitdir = pointer_raw.split("gitdir: ", 1)[1]
canonical_stat = os.stat(canonical)
artifact = pathlib.Path("/var/lib/telemetry-sdk-qualification/dist/telemetry-batch-client-2.8.1.tar.gz")
trust = {
    "pid": pid,
    "start_ticks": int((proc / "stat").read_text().split()[21]),
    "uid": proc.stat().st_uid,
    "cwd": process_cwd(pid),
    "canonical_device": canonical_stat.st_dev,
    "canonical_inode": canonical_stat.st_ino,
    "canonical_common_dir": str(pathlib.Path(canonical, git(canonical, "rev-parse", "--git-common-dir")).resolve()),
    "worktree": worktree,
    "branch": branch,
    "target_oid": git(canonical, "rev-parse", f"refs/heads/{branch}"),
    "head_oid": git(worktree, "rev-parse", "HEAD"),
    "head_tree": git(worktree, "rev-parse", "HEAD^{tree}"),
    "index_tree": git(worktree, "write-tree"),
    "status": git(worktree, "status", "--porcelain"),
    "worktree_pointer_sha256": hashlib.sha256(pointer_raw.encode()).hexdigest(),
    "admin_gitdir": admin_gitdir,
    "admin_device": os.stat(admin_gitdir).st_dev,
    "admin_inode": os.stat(admin_gitdir).st_ino,
    "porcelain_sha256": hashlib.sha256(porcelain.encode()).hexdigest(),
    "generation": int(state["generation"]),
    "artifact_sha256": hashlib.sha256(artifact.read_bytes()).hexdigest(),
}
pathlib.Path(out).write_text(json.dumps(trust, indent=2, sort_keys=True) + "\n")
os.chmod(out, 0o600)
print(f"TRUST_CAPTURED=1 pid={pid} generation={trust['generation']} target_oid={trust['target_oid']}")
PY
