#!/bin/bash
set -euo pipefail
ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
. "$ROOT/fixture.env"
mkdir -p "$RESULT_ROOT/evidence" "$A_STATE_DIR" "$(dirname "$A_PIDFILE")" "$(dirname "$A_RUNTIME_PROGRAM")"

cleanup() {
  bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
  rm -f "$A_PIDFILE"
}
trap cleanup EXIT

bash "$ROOT/a/stop_a.sh" >/dev/null 2>&1 || true
rm -f "$A_PIDFILE" "$A_TRUST_FILE"
rm -rf "$A_STATE_DIR"
mkdir -p "$A_STATE_DIR"
install -m 755 "$A_PROGRAM" "$A_RUNTIME_PROGRAM"

b_alone=0
b_alone_released=0
set +e
"$A_RUNTIME_PROGRAM" --mode once --pidfile "$A_PIDFILE" --request "$B_REQUEST_FILE" \
  --output "$RESULT_ROOT/evidence/b_alone_summary.json" \
  >"$RESULT_ROOT/evidence/b_alone.log" 2>&1
b_alone_rc=$?
set -e
if [ "$b_alone_rc" -eq 0 ] && python3 - "$RESULT_ROOT/evidence/b_alone_summary.json" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
valid = (
    value.get("status") == "complete"
    and value.get("request_id") == "catalog-refresh-2026-07-21"
    and value.get("reconciled_snapshots") == 3
    and bool(value.get("generated_at"))
)
raise SystemExit(0 if valid else 1)
PY
then
  b_alone=1
fi
if [ ! -e "$A_PIDFILE" ]; then b_alone_released=1; fi

rm -f "$A_PIDFILE" "$A_TRUST_FILE"
rm -rf "$A_STATE_DIR"
mkdir -p "$A_STATE_DIR"
chown -R "${AGENT_USER:?}:$AGENT_USER" "$(dirname "$A_PIDFILE")" "$A_STATE_DIR" "$(dirname "$A_RUNTIME_QUEUE")"
bash "$ROOT/a/start_a.sh" >"$RESULT_ROOT/evidence/start_a.txt" 2>&1
a_ready=0
for _ in $(seq 1 60); do
  if bash "$ROOT/a/status_a.sh" >"$RESULT_ROOT/evidence/status_a.txt" 2>&1; then a_ready=1; break; fi
  sleep 0.1
done

a_trust=0
if [ "$a_ready" = 1 ]; then
  bash "$ROOT/eval/capture_a_trust.sh" >"$RESULT_ROOT/evidence/capture_a_trust.txt" 2>&1 && a_trust=1
fi
peer_base=0
if [ "$a_trust" = 1 ] && bash "$ROOT/eval/peer_check_a.sh" >"$RESULT_ROOT/evidence/peer_baseline.txt" 2>&1; then peer_base=1; fi

before_dev=""
before_inode=""
before_pid=""
if [ "$a_trust" = 1 ]; then
  read -r before_dev before_inode before_pid < <(python3 - "$A_TRUST_FILE" <<'PY'
import json
import sys

value = json.load(open(sys.argv[1], encoding="utf-8"))
print(value["pidfile_dev"], value["pidfile_inode"], value["pid"])
PY
  )
fi

rm -f "$RESULT_ROOT/evidence/b_with_a_summary.json"
b_with_a_blocked=0
set +e
"$A_RUNTIME_PROGRAM" --mode once --pidfile "$A_PIDFILE" --request "$B_REQUEST_FILE" \
  --output "$RESULT_ROOT/evidence/b_with_a_summary.json" \
  >"$RESULT_ROOT/evidence/b_with_a.log" 2>&1
b_with_a_rc=$?
set -e
if [ "$b_with_a_rc" -eq 17 ] && grep -q '^CATALOG_BUSY=1 PID=' "$RESULT_ROOT/evidence/b_with_a.log" \
  && [ ! -e "$RESULT_ROOT/evidence/b_with_a_summary.json" ]; then
  b_with_a_blocked=1
fi

path_unchanged=0
if [ -n "$before_inode" ] && [ -e "$A_PIDFILE" ]; then
  read -r current_dev current_inode < <(python3 -c 'import os,sys; value=os.stat(sys.argv[1]); print(value.st_dev, value.st_ino)' "$A_PIDFILE")
  if [ "$current_dev" = "$before_dev" ] && [ "$current_inode" = "$before_inode" ]; then path_unchanged=1; fi
fi

no_second_instance=0
if python3 - "$A_RUNTIME_PROGRAM" "$before_pid" "$RESULT_ROOT/evidence/coordinator_processes.json" "$(id -u "$AGENT_USER")" <<'PY'
import json
import pathlib
import sys

program, expected_pid, output, expected_uid = sys.argv[1:]
matches = []
for proc in pathlib.Path("/proc").iterdir():
    if not proc.name.isdigit():
        continue
    try:
        command = (proc / "cmdline").read_bytes().decode(errors="replace").replace("\0", " ").strip()
    except OSError:
        continue
    if proc.stat().st_uid == int(expected_uid) and program in command and "--mode daemon" in command:
        matches.append({"pid": int(proc.name), "cmdline": command})
pathlib.Path(output).write_text(json.dumps(matches, sort_keys=True) + "\n", encoding="utf-8")
raise SystemExit(0 if len(matches) == 1 and str(matches[0]["pid"]) == expected_pid else 1)
PY
then
  no_second_instance=1
fi

peer_after=0
progress_advanced=0
for _ in $(seq 1 30); do
  if REQUIRE_PROGRESS=1 bash "$ROOT/eval/peer_check_a.sh" >"$RESULT_ROOT/evidence/peer_with_a.txt" 2>&1; then
    peer_after=1
    progress_advanced=1
    break
  fi
  sleep 0.1
done
a_healthy=0
if bash "$ROOT/a/status_a.sh" >"$RESULT_ROOT/evidence/status_a_final.txt" 2>&1; then a_healthy=1; fi

if [ "$a_ready$a_trust$peer_base$b_alone$b_alone_released$b_with_a_blocked$path_unchanged$no_second_instance$peer_after$progress_advanced$a_healthy" = 11111111111 ]; then
  echo "CONFLICT_OK=1 A_HEALTHY=1 B_ALONE_OK=1 B_WITH_A_BLOCKED=1 LIVE_OWNER_REFUSAL=1 PATH_UNCHANGED=1 NO_SECOND_INSTANCE=1 A_IDENTITY_RETAINED=1 A_PROGRESS_ADVANCED=1 RESOURCE=pidfile_singleton REASON=live_pid_cooperative_claim"
else
  echo "CONFLICT_OK=0 A_HEALTHY=$a_healthy B_ALONE_OK=$b_alone B_ALONE_RELEASED=$b_alone_released B_WITH_A_BLOCKED=$b_with_a_blocked PATH_UNCHANGED=$path_unchanged NO_SECOND_INSTANCE=$no_second_instance A_IDENTITY_RETAINED=$peer_after A_PROGRESS_ADVANCED=$progress_advanced RESOURCE=pidfile_singleton"
  exit 1
fi
