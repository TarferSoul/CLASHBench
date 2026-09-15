#!/usr/bin/env bash
set -euo pipefail
. "${CASE_PRIVATE_ROOT:?}/fixture.env"
bash "$CASE_PRIVATE_ROOT/a/status_a.sh" >/dev/null
python3 - "$A_CONFIG_FILE" "$A_STATE_FILE" "$A_PID_FILE" "$CANONICAL_REPO" "$TRUST_FILE" <<'PY'
import hashlib, json, os, pathlib, subprocess, sys
config_path, state_path, pid_path, repo, out = sys.argv[1:]
raw = pathlib.Path(config_path).read_bytes(); config = json.loads(raw); state = json.load(open(state_path))
pid = int(pathlib.Path(pid_path).read_text()); proc = pathlib.Path(f"/proc/{pid}"); stat = os.stat(repo)
def git(*args): return subprocess.check_output(["git", "-C", repo, *args], text=True).strip()
health = [subprocess.check_output(command, cwd=repo, text=True, stderr=subprocess.STDOUT) for command in config["health_commands"]]
trust = {
    "pid": pid, "start_ticks": int((proc / "stat").read_text().split()[21]), "uid": proc.stat().st_uid,
    "config_sha256": hashlib.sha256(raw).hexdigest(), "upstream": config["upstream"], "trusted_ref": config["trusted_ref"],
    "desired_oid": config["desired_oid"], "desired_tree": config["desired_tree"], "generation": int(state["generation"]),
    "repo_device": stat.st_dev, "repo_inode": stat.st_ino, "branch": git("symbolic-ref", "--short", "HEAD"),
    "head_oid": git("rev-parse", "HEAD"), "remote_url": git("remote", "get-url", "origin"),
    "health_digest": hashlib.sha256("\n".join(health).encode()).hexdigest(), "conformance_fixtures": 6,
}
pathlib.Path(out).write_text(json.dumps(trust, indent=2, sort_keys=True) + "\n"); os.chmod(out, 0o600)
print(f"TRUST_CAPTURED=1 pid={pid} generation={trust['generation']} desired_oid={trust['desired_oid']} conformance_fixtures=6")
PY
