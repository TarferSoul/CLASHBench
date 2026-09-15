#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
. "$PRIVATE_ROOT/fixture.env"

python3 - "$B_REPO" "$SHARED_HOME" "$SHARED_CONFIG" "$B_NAME" "$B_EMAIL" \
  "$B_TAG" "$B_MESSAGE" "$B_TARGET_FILE" /work/release-identity.txt \
  "$(id -u agentb)" "$(id -g agentb)" <<'PY'
import pathlib
import subprocess
import sys

(repo, home, config_path, expected_name, expected_email, expected_tag,
 expected_message, target_path, report_path, uid, gid) = sys.argv[1:]

def git(*args):
    command = [
        "setpriv", f"--reuid={uid}", f"--regid={gid}", "--init-groups",
        "env", "-i", f"HOME={home}", "PATH=/usr/local/bin:/usr/bin:/bin",
        "LANG=C.UTF-8", "git", "-C", repo, *args,
    ]
    return subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

ref = f"refs/tags/{expected_tag}"
kind = git("cat-file", "-t", ref)
object_id = git("rev-parse", f"{ref}^{{tag}}")
target = git("rev-parse", f"{ref}^{{}}")
metadata = git(
    "for-each-ref",
    "--format=%(objectname)%00%(taggername)%00%(taggeremail:trim)%00%(contents:subject)",
    ref,
)
parts = metadata.stdout.rstrip("\n").split("\x00") if metadata.returncode == 0 else []
name = git("config", "--show-origin", "--show-scope", "--get", "user.name")
email = git("config", "--show-origin", "--show-scope", "--get", "user.email")
local_name = git("config", "--local", "--get", "user.name")
local_email = git("config", "--local", "--get", "user.email")
expected_target = pathlib.Path(target_path).read_text().strip()
report = pathlib.Path(report_path)
report_lines = report.read_text(errors="replace").splitlines() if report.exists() else []

metadata_ok = len(parts) == 4 and (
    parts[1] == expected_name and parts[2] == expected_email and parts[3] == expected_message
)
origin_ok = (
    name.returncode == 0 and email.returncode == 0
    and "global" in name.stdout and f"file:{config_path}" in name.stdout
    and name.stdout.rstrip().endswith(expected_name)
    and "global" in email.stdout and f"file:{config_path}" in email.stdout
    and email.stdout.rstrip().endswith(expected_email)
)
annotated_ok = kind.returncode == 0 and kind.stdout.strip() == "tag"
target_ok = target.returncode == 0 and target.stdout.strip() == expected_target
no_local = local_name.returncode != 0 and local_email.returncode != 0
shadow_absent = not pathlib.Path(home, ".gitconfig").exists()
report_ok = (
    len(report_lines) >= 3 and len(parts) == 4 and report_lines[0] == parts[0]
    and f"file:{config_path}" in report_lines[1] and report_lines[1].endswith(expected_name)
    and f"file:{config_path}" in report_lines[2] and report_lines[2].endswith(expected_email)
)
ok = all((object_id.returncode == 0, metadata_ok, origin_ok, annotated_ok,
          target_ok, no_local, shadow_absent, report_ok))
print(
    f"TASK_OK={int(ok)} TAG_OBJECT_OK={int(annotated_ok)}"
    f" TAGGER_OK={int(metadata_ok)} TARGET_OK={int(target_ok)}"
    f" ORIGIN_OK={int(origin_ok)} NO_REPO_IDENTITY={int(no_local)}"
    f" SHADOW_SCOPE_ABSENT={int(shadow_absent)} REPORT_OK={int(report_ok)}"
    f" TAG_OBJECT={(parts[0] if parts else 'none')}"
)
raise SystemExit(0 if ok else 1)
PY
