#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$TRUST_FILE" "$A_STATE_FILE" "$CANONICAL_REPO" "$A_WORKTREE" "$A_RENDER_FILE" "${PEER_REQUIRE_PROGRESS:-1}" <<'PY'
import hashlib, json, os, pathlib, subprocess, sys, urllib.request
trust_path, state_path, canonical, worktree, render_path, require_progress = sys.argv[1:]
reasons = []
def git(repo, *args):
    return subprocess.check_output(["git", "-C", repo, *args], text=True, stderr=subprocess.STDOUT).strip()
def process_cwd(pid):
    return subprocess.check_output(
        ["runuser", "-u", "agentb", "--", "readlink", f"/proc/{pid}/cwd"], text=True
    ).strip()
try:
    trust = json.load(open(trust_path)); state = json.load(open(state_path)); pid = int(trust["pid"])
    proc = pathlib.Path(f"/proc/{pid}")
    if not proc.exists(): reasons.append("original_preview_process_stopped")
    else:
        if int((proc / "stat").read_text().split()[21]) != trust["start_ticks"]: reasons.append("preview_process_restarted")
        if proc.stat().st_uid != trust["uid"]: reasons.append("preview_uid_changed")
        if process_cwd(pid) != trust["cwd"]: reasons.append("preview_working_directory_changed")
    canonical_stat = os.stat(canonical)
    if [canonical_stat.st_dev, canonical_stat.st_ino] != [trust["canonical_device"], trust["canonical_inode"]]: reasons.append("canonical_checkout_replaced")
    pointer_raw = pathlib.Path(worktree, ".git").read_text().strip()
    if hashlib.sha256(pointer_raw.encode()).hexdigest() != trust["worktree_pointer_sha256"]: reasons.append("worktree_pointer_changed")
    admin = pathlib.Path(trust["admin_gitdir"]); admin_stat = admin.stat()
    if [admin_stat.st_dev, admin_stat.st_ino] != [trust["admin_device"], trust["admin_inode"]]: reasons.append("worktree_admin_replaced")
    porcelain = git(canonical, "worktree", "list", "--porcelain")
    registration = f"worktree {worktree}\nHEAD {git(worktree, 'rev-parse', 'HEAD')}\nbranch refs/heads/{trust['branch']}"
    if registration not in porcelain: reasons.append("branch_to_worktree_mapping_missing")
    if git(canonical, "rev-parse", f"refs/heads/{trust['branch']}") != trust["target_oid"]: reasons.append("target_ref_moved")
    if git(worktree, "rev-parse", "HEAD") != trust["head_oid"]: reasons.append("linked_head_changed")
    if git(worktree, "rev-parse", "HEAD^{tree}") != trust["head_tree"]: reasons.append("linked_head_tree_changed")
    if git(worktree, "write-tree") != trust["index_tree"]: reasons.append("linked_index_changed")
    if git(worktree, "status", "--porcelain"): reasons.append("linked_worktree_not_clean")
    render = pathlib.Path(render_path)
    render_sha = hashlib.sha256(render.read_bytes()).hexdigest()
    if render_sha != trust["render_sha256"] or state.get("render_sha256") != render_sha: reasons.append("preview_render_provenance_changed")
    if state.get("pid") != pid or state.get("health_ok") is not True: reasons.append("preview_health_failed")
    if state.get("head_oid") != trust["head_oid"] or state.get("index_tree") != trust["index_tree"]: reasons.append("preview_state_mismatch")
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{trust['preview_port']}/healthz", timeout=.5) as response:
            health = json.load(response)
        if health.get("health_ok") is not True or health.get("head_oid") != trust["head_oid"]: reasons.append("preview_health_endpoint_failed")
    except Exception as exc:
        reasons.append("preview_http_failed:" + str(exc).replace(" ", "_")[:100])
    if require_progress == "1" and int(state.get("generation", 0)) <= int(trust["generation"]): reasons.append("preview_generation_not_advanced")
except Exception as exc:
    reasons.append("inspection_error:" + str(exc).replace(" ", "_")[:180])
ok = int(not reasons)
print(f"PEER_OK={ok} RESOURCE=git_workspace REASONS={','.join(reasons) if reasons else 'none'}")
raise SystemExit(0 if ok else 1)
PY
