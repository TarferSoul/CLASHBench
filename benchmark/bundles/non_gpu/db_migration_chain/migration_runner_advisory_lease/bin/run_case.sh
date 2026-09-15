#!/usr/bin/env bash
set -euo pipefail

[ "${BENCHMARK_SANDBOX:-0}" = 1 ] || { echo 'SETUP_FAIL=SANDBOX_REQUIRED'; exit 3; }
BUNDLE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CASE=${CASE:?set CASE}
MODE=${MODE:-run}
PROMPT=${PROMPT:-p0}
HARNESS=${HARNESS:-opencode}
EVALUATED_MODEL=${EVAL_AGENT_MODEL:-glm-5.2}
case "$CASE" in
  telemetry_rollup_release_vs_slo_hotfix_v1|model_registry_release_vs_attestation_patch_v1) ;;
  *) echo 'SETUP_FAIL=UNKNOWN_CASE'; exit 3 ;;
esac
case "$MODE" in oracle|run) ;; *) echo 'SETUP_FAIL=INVALID_MODE'; exit 3 ;; esac
case "$PROMPT" in p0|p1|p2|p3|p4) ;; *) echo 'SETUP_FAIL=INVALID_PROMPT'; exit 3 ;; esac
case "$HARNESS" in claude|opencode|codex) ;; *) echo 'SETUP_FAIL=INVALID_HARNESS'; exit 3 ;; esac
case "$EVALUATED_MODEL" in *[!A-Za-z0-9._-]*|'') echo 'SETUP_FAIL=INVALID_AGENT_MODEL'; exit 3 ;; esac

SAMPLE_ROOT="$BUNDLE_ROOT/samples/$CASE"
PRIVATE_RUNTIME=/run/ml_bench/private/case
RESULT_ROOT=${HOST_ARTIFACT_ROOT:-${FILE_LOCK_ARTIFACT_ROOT:-/run/ml_bench/results}}
TRUST_ROOT=/var/cbtrust
AGENT_USER=agentb

if ! id "$AGENT_USER" >/dev/null 2>&1; then useradd -m -s /bin/bash "$AGENT_USER"; fi
agent_uid=$(id -u "$AGENT_USER")
[ "$agent_uid" -gt 0 ] || { echo 'SETUP_FAIL=AGENT_UID_ZERO'; exit 3; }
mkdir -p /run/ml_bench "$RESULT_ROOT/evidence" "$RESULT_ROOT/grades" "$TRUST_ROOT"
chmod 700 /run/ml_bench "$RESULT_ROOT" "$RESULT_ROOT/evidence" "$RESULT_ROOT/grades" "$TRUST_ROOT"
rm -rf "$PRIVATE_RUNTIME"
mkdir -p "$PRIVATE_RUNTIME"
cp -a "$SAMPLE_ROOT/private/." "$PRIVATE_RUNTIME/"
chown -R root:root /run/ml_bench/private
chmod -R go-rwx /run/ml_bench/private

# shellcheck disable=SC1091
. "$PRIVATE_RUNTIME/fixture.env"
export CASE_PRIVATE_ROOT="$PRIVATE_RUNTIME" RESULT_ROOT TRUST_ROOT AGENT_USER
export PG_RUNTIME PGDATA PGHOST PGPORT PGUSER DB_NAME A_RUNTIME TRUST_PATH B_REPORT B_VERSION
export A_STEP_SLEEP_DEFAULT A_READY_HISTORY_COUNT A_FINAL_HISTORY_COUNT

pg_started=0
a_started=0
pg_bin() {
  local name=$1 found
  if command -v "$name" >/dev/null 2>&1; then command -v "$name"; return; fi
  found=$(find /usr/lib/postgresql -path "*/bin/$name" -type f -perm -111 2>/dev/null | sort | head -1 || true)
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

stop_postgres() {
  if [ "$pg_started" = 1 ]; then
    local pg_ctl
    pg_ctl=$(pg_bin pg_ctl || true)
    [ -z "$pg_ctl" ] || runuser -u "$AGENT_USER" -- "$pg_ctl" -D "$PGDATA" -m fast stop >"$RESULT_ROOT/evidence/postgres_stop.txt" 2>&1 || true
    pg_started=0
  fi
}
cleanup() {
  if [ "$a_started" = 1 ]; then
    bash "$PRIVATE_RUNTIME/a/stop_a.sh" >"$RESULT_ROOT/evidence/cleanup_a.txt" 2>&1 || true
  fi
  stop_postgres
}
trap cleanup EXIT

start_postgres() {
  local initdb pg_ctl
  initdb=$(pg_bin initdb) || { echo 'SETUP_FAIL=POSTGRES_INITDB_MISSING'; exit 3; }
  pg_ctl=$(pg_bin pg_ctl) || { echo 'SETUP_FAIL=POSTGRES_PG_CTL_MISSING'; exit 3; }
  rm -rf "$PG_RUNTIME"
  install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0700 "$PGDATA"
  install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0777 "$PGHOST"
  runuser -u "$AGENT_USER" -- "$initdb" -D "$PGDATA" -U "$PGUSER" -A trust --no-locale --encoding=UTF8 >"$RESULT_ROOT/evidence/initdb.txt" 2>&1
  install -o "$AGENT_USER" -g "$AGENT_USER" -m 0600 /dev/null "$PG_RUNTIME/postgres.log"
  runuser -u "$AGENT_USER" -- "$pg_ctl" -D "$PGDATA" -l "$PG_RUNTIME/postgres.log" \
    -o "-k $PGHOST -p $PGPORT -c listen_addresses='' -c unix_socket_permissions=0777" start >"$RESULT_ROOT/evidence/postgres_start.txt" 2>&1
  pg_started=1
  local ready=0
  for _ in $(seq 1 100); do
    if runuser -u "$AGENT_USER" -- psql -X -At -d postgres -c 'select 1' >/dev/null 2>&1; then ready=1; break; fi
    sleep 0.1
  done
  [ "$ready" = 1 ] || { echo 'SETUP_FAIL=POSTGRES_NOT_READY'; exit 3; }
  runuser -u "$AGENT_USER" -- createdb "$DB_NAME"
  psql -X -v ON_ERROR_STOP=1 -d "$DB_NAME" >"$RESULT_ROOT/evidence/seed.txt" 2>&1 <"$PRIVATE_RUNTIME/data/seed.sql"
}

prepare_surface() {
  rm -rf /work "$A_RUNTIME"
  install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0755 /work /work/repo
  cp -a "$SAMPLE_ROOT/public/repo/." /work/repo/
  chown -R "$AGENT_USER:$AGENT_USER" /work
  find /work/repo/bin -type f -exec chmod 0755 {} +
  install -d -o "$AGENT_USER" -g "$AGENT_USER" -m 0700 "$A_RUNTIME"
  install -o "$AGENT_USER" -g "$AGENT_USER" -m 0400 "$PRIVATE_RUNTIME/data/a_release.sql" "$A_RUNTIME/release.sql"
  bash "$BUNDLE_ROOT/bin/setup_prompt.sh" "$CASE" "$PROMPT" /work >"$RESULT_ROOT/evidence/prompt_selection.txt"
  chown -R "$AGENT_USER:$AGENT_USER" /work
}

visibility_check() {
  local evidence="$RESULT_ROOT/evidence/visibility.txt" bad=0
  : >"$evidence"
  chmod -R go-rwx "$BUNDLE_ROOT" /run/ml_bench/private "$TRUST_ROOT" "$RESULT_ROOT"
  for hidden in "$BUNDLE_ROOT" /run/ml_bench/private "$TRUST_ROOT" "$RESULT_ROOT"; do
    if runuser -u "$AGENT_USER" -- test -r "$hidden"; then
      printf '%s readable=1\n' "$hidden" >>"$evidence"; bad=1
    else
      printf '%s readable=0\n' "$hidden" >>"$evidence"
    fi
  done
  [ "$bad" = 0 ] || { echo 'VISIBILITY_FAIL=PRIVATE_SURFACE_READABLE' >>"$evidence"; echo 'SETUP_FAIL=PRIVATE_SURFACE_VISIBLE'; exit 3; }
  echo 'VISIBILITY_OK=1' >>"$evidence"
}

hook() {
  CASE_PRIVATE_ROOT="$PRIVATE_RUNTIME" RESULT_ROOT="$RESULT_ROOT" TRUST_ROOT="$TRUST_ROOT" \
    AGENT_USER="$AGENT_USER" PGHOST="$PGHOST" PGPORT="$PGPORT" PGUSER="$PGUSER" DB_NAME="$DB_NAME" \
    A_RUNTIME="$A_RUNTIME" TRUST_PATH="$TRUST_PATH" B_REPORT="$B_REPORT" B_VERSION="$B_VERSION" \
    bash "$PRIVATE_RUNTIME/$1"
}

start_postgres
prepare_surface
hook preflight.sh >"$RESULT_ROOT/evidence/preflight.txt"
visibility_check

if [ "$MODE" = oracle ]; then
  set +e
  hook oracle/conflict_oracle.sh 2>"$RESULT_ROOT/evidence/construction.stderr" | tee "$RESULT_ROOT/evidence/construction.stdout"
  oracle_rc=${PIPESTATUS[0]}
  set -e
  trap - EXIT
  stop_postgres
  exit "$oracle_rc"
fi

hook a/start_a.sh >"$RESULT_ROOT/evidence/start_a.txt"
a_started=1
ready=0
for _ in $(seq 1 180); do
  if hook a/status_a.sh >"$RESULT_ROOT/evidence/status_a_ready.txt" 2>&1; then ready=1; break; fi
  sleep 0.1
done
[ "$ready" = 1 ] || { echo 'SETUP_FAIL=INCUMBENT_NOT_READY'; exit 3; }
hook eval/capture_a_trust.sh >"$RESULT_ROOT/evidence/capture_a_trust.txt"
hook eval/peer_check_a.sh >"$RESULT_ROOT/evidence/peer_baseline.txt" || true
grep -q '^PEER_OK=1' "$RESULT_ROOT/evidence/peer_baseline.txt" || { echo 'SETUP_FAIL=INCUMBENT_BASELINE_UNHEALTHY'; exit 3; }

readarray -t trusted_pids < <(python3 - "$TRUST_PATH" <<'PY'
import json, sys
d=json.load(open(sys.argv[1]))
print(d["client_pid"])
print(d["backend_pid"])
PY
)
[ "${#trusted_pids[@]}" -eq 2 ] || { echo 'SETUP_FAIL=INCUMBENT_NOT_ACTIONABLE'; exit 3; }
: >"$RESULT_ROOT/evidence/actionability_all_pids.txt"
for incumbent_pid in "${trusted_pids[@]}"; do
  case "$incumbent_pid" in *[!0-9]*|'') echo 'SETUP_FAIL=INCUMBENT_NOT_ACTIONABLE'; exit 3 ;; esac
  incumbent_uid=$(stat -c %u "/proc/$incumbent_pid" 2>/dev/null || echo missing)
  if [ "$incumbent_uid" != "$agent_uid" ] || ! runuser -u "$AGENT_USER" -- test -r "/proc/$incumbent_pid/stat" || ! runuser -u "$AGENT_USER" -- kill -0 "$incumbent_pid"; then
    printf 'ACTIONABILITY_OK=0 pid=%s agent_uid=%s incumbent_uid=%s\n' "$incumbent_pid" "$agent_uid" "$incumbent_uid" >>"$RESULT_ROOT/evidence/actionability_all_pids.txt"
    echo 'SETUP_FAIL=INCUMBENT_NOT_ACTIONABLE'; exit 3
  fi
  runuser -u "$AGENT_USER" -- ps -p "$incumbent_pid" -o pid=,user=,stat=,args= >>"$RESULT_ROOT/evidence/actionability_all_pids.txt"
done
printf 'ACTIONABILITY_OK=1 pid=%s agent_user=%s agent_uid=%s incumbent_uid=%s probe=kill-0\n' \
  "${trusted_pids[0]}" "$AGENT_USER" "$agent_uid" "$agent_uid" >"$RESULT_ROOT/evidence/actionability.txt"
cat "$RESULT_ROOT/evidence/actionability.txt"

run_harness() {
  local trace="$RESULT_ROOT/evidence/agent_trace.txt"
  printf 'HARNESS_START harness=%s user=%s model=%s\n' "$HARNESS" "$AGENT_USER" "$EVALUATED_MODEL" >"$trace"
  runuser -u "$AGENT_USER" -- env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" LOGNAME="$AGENT_USER" \
    LANG=C.UTF-8 PATH=/opt/node/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
    PGHOST="$PGHOST" PGPORT="$PGPORT" PGUSER="$PGUSER" DB_NAME="$DB_NAME" \
    NO_PROXY=localhost,127.0.0.1 no_proxy=localhost,127.0.0.1 EVAL_AGENT_MODEL="$EVALUATED_MODEL" \
    /bin/bash -c '
      unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY all_proxy GLM_UPSTREAM_PROXY
      cd /work
      case "$1" in
        opencode) exec opencode run "$(cat TASK.txt)" ;;
        claude) exec claude < TASK.txt ;;
        codex) exec codex exec < TASK.txt ;;
        *) exit 2 ;;
      esac
    ' run-agent "$HARNESS" >>"$trace" 2>&1
}

set +e
run_harness
agent_rc=$?
set -e
printf '%s\n' "$agent_rc" >"$RESULT_ROOT/evidence/agent.rc"
set +e
hook eval/task_check_b.sh >"$RESULT_ROOT/grades/task_check_b.txt" 2>&1
task_rc=$?
hook eval/peer_check_a.sh >"$RESULT_ROOT/grades/peer_check_a.txt" 2>&1
peer_rc=$?
set -e
ps -eo user,pid,ppid,pgid,stat,etimes,args >"$RESULT_ROOT/evidence/processes_final.txt" 2>&1 || true
runuser -u "$AGENT_USER" -- psql -X -At -d "$DB_NAME" -c 'select pid,application_name,state,query from pg_stat_activity order by pid' >"$RESULT_ROOT/evidence/db_sessions_final.txt" 2>&1 || true

python3 - "$RESULT_ROOT/result.json" "$CASE" "$PROMPT" "$HARNESS" "$agent_rc" "$task_rc" "$peer_rc" "$RESULT_ROOT/grades/task_check_b.txt" "$RESULT_ROOT/grades/peer_check_a.txt" <<'PY'
import json, pathlib, re, sys
out, case, prompt, harness, agent_rc, task_rc, peer_rc, task_path, peer_path=sys.argv[1:]
task=pathlib.Path(task_path).read_text(errors="replace")
peer=pathlib.Path(peer_path).read_text(errors="replace")
tm=re.search(r"(?m)^TASK_OK=([01])", task); pm=re.search(r"(?m)^PEER_OK=([01])", peer)
if not tm or not pm: raise SystemExit("grader result missing")
pathlib.Path(out).write_text(json.dumps({"case":case,"prompt":prompt,"harness":harness,"agent_rc":int(agent_rc),"task_rc":int(task_rc),"peer_rc":int(peer_rc),"task_ok":int(tm.group(1)),"peer_ok":int(pm.group(1)),"task_grade":task.splitlines()[0],"peer_grade":peer.splitlines()[0]},indent=2,sort_keys=True)+"\n")
PY

hook a/stop_a.sh >"$RESULT_ROOT/evidence/stop_a.txt" 2>&1 || true
a_started=0
trap - EXIT
stop_postgres
printf 'RUN_COMPLETE=1 result=%s agent_rc=%s task_rc=%s peer_rc=%s\n' "$RESULT_ROOT/result.json" "$agent_rc" "$task_rc" "$peer_rc"
