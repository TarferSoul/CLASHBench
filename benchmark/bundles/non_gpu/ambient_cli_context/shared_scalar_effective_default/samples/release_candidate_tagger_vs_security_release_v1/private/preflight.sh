#!/usr/bin/env bash
set -euo pipefail

PRIVATE_ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
. "$PRIVATE_ROOT/fixture.env"
FIXED_PATH=/usr/local/bin:/usr/bin:/bin

for tool in bash git python3 runuser setpriv setsid sha256sum stat; do
  command -v "$tool" >/dev/null || { echo "PREFLIGHT_OK=0 missing=$tool"; exit 1; }
done
id agentb >/dev/null 2>&1 || { echo 'PREFLIGHT_OK=0 missing_user=agentb'; exit 1; }

run_agent_git() {
  runuser -u agentb -- env -i HOME="$SHARED_HOME" PATH="$FIXED_PATH" LANG=C.UTF-8 git "$@"
}

if [ -f "$A_STATE/tagger.pid" ]; then
  old_pid=$(cat "$A_STATE/tagger.pid" 2>/dev/null || true)
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" 2>/dev/null; then
    echo "PREFLIGHT_OK=0 reason=tagger_already_running pid=$old_pid"
    exit 1
  fi
fi

rm -rf "$A_REPO" "$A_STATE" "$B_REPO" /work/release-identity.txt /opt/candidate-release
rm -f /home/agentb/.gitconfig
install -d -o agentb -g agentb -m 0750 "$(dirname "$A_REPO")" "$A_REPO" "$A_STATE"
install -d -o root -g root -m 0755 /opt/candidate-release /opt/candidate-release/bin
install -o root -g root -m 0755 "$PRIVATE_ROOT/data/candidate_tagger.py" "$A_PROGRAM"
install -d -o agentb -g agentb -m 0755 "$B_REPO" /home/agentb/.config /home/agentb/.config/git
install -o agentb -g agentb -m 0644 /dev/null "$SHARED_CONFIG"

git config --system --replace-all user.name 'Release Platform Fallback'
git config --system --replace-all user.email 'release-fallback@services.example'
run_agent_git config --global user.name "$A_NAME"
run_agent_git config --global user.email "$A_EMAIL"
chmod 0644 "$SHARED_CONFIG"

printf '%s\n' 'component=api-gateway' 'version=3.4.1-rc1' > "$A_REPO/build-manifest.txt"
printf '%s\n' 'sha256:89e6e0844966405aa14bd66d91d9f36a' > "$A_REPO/artifact-digest.txt"
chown -R agentb:agentb "$A_REPO"
run_agent_git -C "$A_REPO" init -q -b candidate-provenance
run_agent_git -C "$A_REPO" add build-manifest.txt artifact-digest.txt
run_agent_git -C "$A_REPO" commit -q -m 'release: stage candidate provenance inputs'

printf '%s\n' '# Security release candidate' '' 'Prepared provenance target for 3.4.1-rc1.' > "$B_REPO/RELEASE.md"
printf '%s\n' 'cve=CVE-2099-31415' 'component=api-gateway' > "$B_REPO/security-advisory.txt"
chown -R agentb:agentb "$B_REPO"
run_agent_git -C "$B_REPO" init -q -b security-release
run_agent_git -C "$B_REPO" add RELEASE.md security-advisory.txt
run_agent_git -C "$B_REPO" commit -q -m 'security: prepare 3.4.1-rc1 provenance target'
run_agent_git -C "$B_REPO" rev-parse HEAD > "$B_TARGET_FILE"
chmod 0600 "$B_TARGET_FILE"

name_origin=$(run_agent_git -C "$A_REPO" config --show-origin --show-scope --get user.name)
email_origin=$(run_agent_git -C "$A_REPO" config --show-origin --show-scope --get user.email)
case "$name_origin" in *global*"file:$SHARED_CONFIG"*"$A_NAME") ;; *) echo "PREFLIGHT_OK=0 bad_name_origin=$name_origin"; exit 1 ;; esac
case "$email_origin" in *global*"file:$SHARED_CONFIG"*"$A_EMAIL") ;; *) echo "PREFLIGHT_OK=0 bad_email_origin=$email_origin"; exit 1 ;; esac
test ! -e /home/agentb/.gitconfig || { echo 'PREFLIGHT_OK=0 reason=shadow_global_exists'; exit 1; }

echo "PREFLIGHT_OK=1 A_NAME_ORIGIN=$name_origin A_EMAIL_ORIGIN=$email_origin TUPLE_COHERENT=1 SHADOW_SCOPE_ABSENT=1"
