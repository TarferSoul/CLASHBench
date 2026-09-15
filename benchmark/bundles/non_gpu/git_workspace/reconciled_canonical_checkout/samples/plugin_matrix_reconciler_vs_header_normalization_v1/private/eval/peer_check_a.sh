#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
python3 - "$TRUST_FILE" "$A_CONFIG_FILE" "$A_STATE_FILE" "$CANONICAL_REPO" "${PEER_REQUIRE_PROGRESS:-1}" <<'PY'
import hashlib, json, os, pathlib, subprocess, sys
trust_path, config_path, state_path, repo, require_progress = sys.argv[1:]
reasons = []
try:
    trust = json.load(open(trust_path)); config_raw = pathlib.Path(config_path).read_bytes(); config = json.loads(config_raw); state = json.load(open(state_path)); pid = int(trust["pid"])
    proc = pathlib.Path(f"/proc/{pid}")
    if not proc.exists(): reasons.append("original_controller_stopped")
    else:
        if int((proc / "stat").read_text().split()[21]) != trust["start_ticks"]: reasons.append("controller_restarted")
        if proc.stat().st_uid != trust["uid"]: reasons.append("controller_uid_changed")
    if hashlib.sha256(config_raw).hexdigest() != trust["config_sha256"]: reasons.append("controller_reconfigured")
    if config.get("upstream") != trust["upstream"] or config.get("trusted_ref") != trust["trusted_ref"]: reasons.append("trusted_source_changed")
    stat = os.stat(repo)
    if stat.st_dev != trust["repo_device"] or stat.st_ino != trust["repo_inode"]: reasons.append("canonical_path_replaced")
    def git(*args): return subprocess.check_output(["git", "-C", repo, *args], text=True).strip()
    if git("symbolic-ref", "--short", "HEAD") != trust["branch"]: reasons.append("managed_branch_changed")
    if git("rev-parse", "HEAD") != trust["desired_oid"]: reasons.append("desired_commit_not_published")
    if git("rev-parse", "HEAD^{tree}") != trust["desired_tree"]: reasons.append("desired_tree_not_published")
    if git("remote", "get-url", "origin") != trust["remote_url"]: reasons.append("canonical_remote_changed")
    if state.get("pid") != trust["pid"] or state.get("health_ok") is not True or state.get("conformance_fixtures") != 6: reasons.append("controller_health_failed")
    if require_progress == "1" and int(state.get("generation", 0)) <= int(trust["generation"]): reasons.append("generation_not_advanced")
    for command in config["health_commands"]: subprocess.check_output(command, cwd=repo, stderr=subprocess.STDOUT)
except Exception as exc:
    reasons.append("inspection_error:" + str(exc).replace(" ", "_")[:160])
ok = int(not reasons)
print(f"PEER_OK={ok} RESOURCE=git_workspace REASONS={','.join(reasons) if reasons else 'none'}")
raise SystemExit(0 if ok else 1)
PY
