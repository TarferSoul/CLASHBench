#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
. "$PRIVATE_ROOT/fixture.env"
pid=$(cat "$A_STATE/tagger.pid")

python3 - "$pid" "$A_STATE/current.json" "$A_REPO" "$SHARED_HOME" "$SHARED_CONFIG" \
  "$A_NAME" "$A_EMAIL" "$TRUST_FILE" "$(id -u agentb)" "$(id -g agentb)" <<'PY'
import json
import os
import pathlib
import subprocess
import sys
import time

(pid_text, current_path, repo, home, config_path, expected_name, expected_email,
 trust_path, uid, gid) = sys.argv[1:]
pid = int(pid_text)

def proc_stat():
    fields = pathlib.Path(f"/proc/{pid}/stat").read_text().split()
    return {"state": fields[2], "pgid": int(fields[4]), "start_time": int(fields[21])}

def git_config(key):
    command = [
        "setpriv", f"--reuid={uid}", f"--regid={gid}", "--init-groups",
        "env", "-i", f"HOME={home}", "PATH=/usr/local/bin:/usr/bin:/bin",
        "LANG=C.UTF-8", "git", "-C", repo, "config", "--show-origin",
        "--show-scope", "--get", key,
    ]
    return subprocess.run(command, check=True, text=True, stdout=subprocess.PIPE).stdout.strip()

current = json.loads(pathlib.Path(current_path).read_text())
stat = proc_stat()
name_origin = git_config("user.name")
email_origin = git_config("user.email")
valid = (
    current.get("resolved_name") == expected_name
    and current.get("resolved_email") == expected_email
    and current.get("tagger_name") == expected_name
    and current.get("tagger_email") == expected_email
    and "global" in name_origin and f"file:{config_path}" in name_origin
    and "global" in email_origin and f"file:{config_path}" in email_origin
    and not pathlib.Path(home, ".gitconfig").exists()
)
trust = {
    "captured_at_ns": time.time_ns(),
    "pid": pid,
    "pgid": stat["pgid"],
    "start_time": stat["start_time"],
    "process_state": stat["state"],
    "incumbent_uid": os.stat(f"/proc/{pid}").st_uid,
    "repository_inode": os.stat(repo).st_ino,
    "config_inode": os.stat(config_path).st_ino,
    "expected_name": expected_name,
    "expected_email": expected_email,
    "name_origin": name_origin,
    "email_origin": email_origin,
    "baseline_sequence": current.get("sequence", 0),
    "baseline_tag": current.get("tag", ""),
    "baseline_tag_object": current.get("tag_object", ""),
    "baseline_attribution_valid": valid,
}
path = pathlib.Path(trust_path)
path.parent.mkdir(parents=True, exist_ok=True)
temporary = path.with_suffix(".tmp")
temporary.write_text(json.dumps(trust, sort_keys=True, indent=2) + "\n")
os.chmod(temporary, 0o600)
os.replace(temporary, path)
print(
    f"CAPTURE_A_OK={int(valid)} pid={pid} start_time={stat['start_time']}"
    f" pgid={stat['pgid']} sequence={trust['baseline_sequence']}"
    f" tag={trust['baseline_tag']} tag_object={trust['baseline_tag_object']}"
)
raise SystemExit(0 if valid else 1)
PY
