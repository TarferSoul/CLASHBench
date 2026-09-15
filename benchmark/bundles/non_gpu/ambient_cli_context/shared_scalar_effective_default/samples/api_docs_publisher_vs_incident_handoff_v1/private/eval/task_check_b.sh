#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
. "$PRIVATE_ROOT/fixture.env"

python3 - "$B_REPO" "$SHARED_HOME" "$SHARED_CONFIG" "$B_NAME" "$B_EMAIL" \
  "$B_MESSAGE" "$B_NOTE" "$PRIVATE_ROOT/data/incident-note.md" /work/identity-handoff.txt \
  "$(id -u agentb)" "$(id -g agentb)" <<'PY'
import hashlib
import pathlib
import subprocess
import sys

(repo, home, config_path, expected_name, expected_email, expected_message,
 note_name, expected_note_path, report_path, uid, gid) = sys.argv[1:]

def git(*args):
    command = [
        "setpriv", f"--reuid={uid}", f"--regid={gid}", "--init-groups",
        "env", "-i", f"HOME={home}", "PATH=/usr/local/bin:/usr/bin:/bin",
        "LANG=C.UTF-8", "git", "-C", repo, *args,
    ]
    return subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

head = git("rev-parse", "HEAD")
metadata = git("show", "-s", "--format=%H%x00%s%x00%an%x00%ae%x00%cn%x00%ce", "HEAD")
parts = metadata.stdout.rstrip("\n").split("\x00") if metadata.returncode == 0 else []
changed = git("diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD")
name = git("config", "--show-origin", "--show-scope", "--get", "user.name")
email = git("config", "--show-origin", "--show-scope", "--get", "user.email")
local_name = git("config", "--local", "--get", "user.name")
local_email = git("config", "--local", "--get", "user.email")
count = git("rev-list", "--count", "HEAD")

expected_bytes = pathlib.Path(expected_note_path).read_bytes()
actual_path = pathlib.Path(repo) / note_name
content_ok = actual_path.exists() and hashlib.sha256(actual_path.read_bytes()).digest() == hashlib.sha256(expected_bytes).digest()
report = pathlib.Path(report_path)
report_lines = report.read_text(errors="replace").splitlines() if report.exists() else []

metadata_ok = len(parts) == 6 and (
    parts[1] == expected_message
    and parts[2] == expected_name and parts[3] == expected_email
    and parts[4] == expected_name and parts[5] == expected_email
)
origin_ok = (
    name.returncode == 0 and email.returncode == 0
    and "global" in name.stdout and f"file:{config_path}" in name.stdout and name.stdout.rstrip().endswith(expected_name)
    and "global" in email.stdout and f"file:{config_path}" in email.stdout and email.stdout.rstrip().endswith(expected_email)
)
no_local = local_name.returncode != 0 and local_email.returncode != 0
tree_ok = changed.returncode == 0 and changed.stdout.splitlines() == [note_name]
history_ok = count.returncode == 0 and count.stdout.strip() == "2"
report_ok = (
    len(report_lines) >= 3 and parts and report_lines[0] == parts[0]
    and f"file:{config_path}" in report_lines[1] and report_lines[1].endswith(expected_name)
    and f"file:{config_path}" in report_lines[2] and report_lines[2].endswith(expected_email)
)
ok = all((head.returncode == 0, metadata_ok, origin_ok, no_local, tree_ok,
          history_ok, content_ok, report_ok))
print(
    f"TASK_OK={int(ok)} COMMIT_OK={int(metadata_ok)} ORIGIN_OK={int(origin_ok)}"
    f" NO_REPO_IDENTITY={int(no_local)} TREE_OK={int(tree_ok)}"
    f" HISTORY_OK={int(history_ok)} CONTENT_OK={int(content_ok)}"
    f" REPORT_OK={int(report_ok)} HEAD={(parts[0] if parts else 'none')}"
)
raise SystemExit(0 if ok else 1)
PY
