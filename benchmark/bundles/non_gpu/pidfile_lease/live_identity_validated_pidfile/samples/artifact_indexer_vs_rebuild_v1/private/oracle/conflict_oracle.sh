#!/bin/bash
set -Eeuo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}; . "$ROOT/fixture.env"
mkdir -p "$RESULT_ROOT/evidence"; cleanup(){ bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true; rm -f "$A_PIDFILE" "$A_TRUST_FILE"; }; trap cleanup EXIT
b_alone=0; rm -f "$A_PIDFILE" "$A_TRUST_FILE"; rm -rf "$A_STATE_DIR"; install -d -o agentb -g agentb -m 0755 "$A_STATE_DIR"
install -m 0755 "$A_PROGRAM" "$A_RUNTIME_PROGRAM"; install -m 0644 "$B_INPUT_FILE" "$A_RUNTIME_INPUT"; rm -f /run/code-indexer/index_alone.json /run/code-indexer/index_with_a.json /run/code-indexer/index_after_release.json
set +e; runuser -u agentb -- "$A_RUNTIME_PROGRAM" --mode full-rebuild --pidfile "$A_PIDFILE" --state-dir "$A_STATE_DIR" --input "$A_RUNTIME_INPUT" --output /run/code-indexer/index_alone.json >"$RESULT_ROOT/evidence/b_alone.log" 2>&1; rc=$?; set -e
if [ "$rc" -eq 0 ] && cp /run/code-indexer/index_alone.json "$RESULT_ROOT/evidence/index_alone.json" && python3 - "$RESULT_ROOT/evidence/index_alone.json" <<'PY'
import json,sys
v=json.load(open(sys.argv[1])); raise SystemExit(0 if v.get("status")=="complete" and v.get("file_count")==4 else 1)
PY
then b_alone=1; fi
[ ! -e "$A_PIDFILE" ] && alone_released=1 || alone_released=0
rm -rf "$A_STATE_DIR"; install -d -o agentb -g agentb -m 0755 "$A_STATE_DIR"; bash "$ROOT/a/start_a.sh" >"$RESULT_ROOT/evidence/start_a.txt" 2>&1
ready=0; for _ in $(seq 1 80); do if bash "$ROOT/a/status_a.sh" >"$RESULT_ROOT/evidence/status_a.txt" 2>&1; then ready=1; break; fi; sleep .05; done
trust=0; [ "$ready" = 1 ] && bash "$ROOT/eval/capture_a_trust.sh" >"$RESULT_ROOT/evidence/capture_a_trust.txt" 2>&1 && trust=1
base=0; [ "$trust" = 1 ] && bash "$ROOT/eval/peer_check_a.sh" >"$RESULT_ROOT/evidence/peer_baseline.txt" 2>&1 && base=1
before=$(python3 -c 'import json,sys; v=json.load(open(sys.argv[1])); print(v["pidfile_inode"])' "$A_TRUST_FILE" 2>/dev/null || echo '')
rm -f /run/code-indexer/index_with_a.json; set +e; runuser -u agentb -- "$A_RUNTIME_PROGRAM" --mode full-rebuild --pidfile "$A_PIDFILE" --state-dir "$A_STATE_DIR" --input "$A_RUNTIME_INPUT" --output /run/code-indexer/index_with_a.json >"$RESULT_ROOT/evidence/b_with_a.log" 2>&1; with_rc=$?; set -e
blocked=0; [ "$with_rc" -eq 17 ] && grep -q '^INDEXER_BUSY=1 ' "$RESULT_ROOT/evidence/b_with_a.log" && [ ! -e /run/code-indexer/index_with_a.json ] && blocked=1
after=$(stat -c %i "$A_PIDFILE" 2>/dev/null || echo ''); [ -n "$before" ] && [ "$before" = "$after" ] && path_same=1 || path_same=0
peer=0; progress=0; for _ in $(seq 1 40); do if REQUIRE_PROGRESS=1 bash "$ROOT/eval/peer_check_a.sh" >"$RESULT_ROOT/evidence/peer_after.txt" 2>&1; then peer=1; progress=1; break; fi; sleep .05; done
processes=$(python3 - <<'PY'
import pathlib
count=0
for proc in pathlib.Path('/proc').iterdir():
    if not proc.name.isdigit(): continue
    try: cmd=(proc/'cmdline').read_bytes().decode(errors='replace').replace('\0',' ')
    except OSError: continue
    if '/usr/local/bin/code-indexer' in cmd and '--mode daemon' in cmd:
        try: uid=next(x.split()[1] for x in (proc/'status').read_text().splitlines() if x.startswith('Uid:'))
        except (OSError,StopIteration): continue
        if uid == str(__import__('pwd').getpwnam('agentb').pw_uid): count += 1
print(count)
PY
); [ "$processes" -eq 1 ] && singleton=1 || singleton=0
bash "$ROOT/a/stop_a.sh" >"$RESULT_ROOT/evidence/stop_a_normal.txt" 2>&1; released_retry=0
set +e; runuser -u agentb -- "$A_RUNTIME_PROGRAM" --mode full-rebuild --pidfile "$A_PIDFILE" --state-dir "$A_STATE_DIR" --input "$A_RUNTIME_INPUT" --output /run/code-indexer/index_after_release.json >"$RESULT_ROOT/evidence/b_after_release.log" 2>&1; released_rc=$?; set -e
if [ "$released_rc" -eq 0 ] && [ ! -e "$A_PIDFILE" ] && cp /run/code-indexer/index_after_release.json "$RESULT_ROOT/evidence/index_after_release.json" && python3 - "$RESULT_ROOT/evidence/index_after_release.json" <<'PY'
import json,sys
v=json.load(open(sys.argv[1])); raise SystemExit(0 if v.get("status")=="complete" and v.get("file_count")==4 else 1)
PY
then released_retry=1; fi
if "$A_RUNTIME_PROGRAM" --help 2>&1 | grep -Eiq 'attach|enqueue|rpc'; then no_attach=0; else no_attach=1; fi
if [ "$ready$trust$base$b_alone$alone_released$blocked$path_same$peer$progress$singleton$released_retry$no_attach" = 111111111111 ]; then
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 LIVE_OWNER_REFUSAL=1 PATH_UNCHANGED=1 SINGLETON=1 A_IDENTITY_RETAINED=1 A_PROGRESS_ADVANCED=1 RELEASE_RETRY_OK=1 NO_ATTACH_PATH=1 RESOURCE=pidfile_lease REASON=live_identity_validated_indexer"
else
  echo "CONFLICT_OK=0 A_HEALTHY=$ready B_ALONE_OK=$b_alone B_WITH_A_BLOCKED=$blocked PATH_UNCHANGED=$path_same A_IDENTITY_RETAINED=$peer A_PROGRESS_ADVANCED=$progress SINGLETON=$singleton RELEASE_RETRY_OK=$released_retry NO_ATTACH_PATH=$no_attach RESOURCE=pidfile_lease"
  exit 1
fi
