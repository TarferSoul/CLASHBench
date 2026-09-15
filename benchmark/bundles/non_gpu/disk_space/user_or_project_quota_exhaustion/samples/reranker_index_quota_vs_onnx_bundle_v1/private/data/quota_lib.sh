#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:-/run/ml_bench/private/case}
# shellcheck disable=SC1091
. "$ROOT/fixture.env"

ensure_runtime_user() {
  if ! id "$AGENT_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$AGENT_USER"
  fi
  [ "$(id -u "$AGENT_USER")" -gt 0 ]
}

teardown_quota_domain() {
  [ "$QUOTA_ROOT" = /dev/shm/reranker-lab-project-quota ] || return 1
  rm -rf "$QUOTA_ROOT" "$A_HELPER_ROOT"
  rm -f "$TRUST_FILE"
}

prepare_quota_domain() {
  ensure_runtime_user
  teardown_quota_domain
  mkdir -p "$QUOTA_ROOT"
  [ "$(findmnt -n -o TARGET -T "$QUOTA_ROOT")" = /dev/shm ]
  [ "$(findmnt -n -o FSTYPE -T "$QUOTA_ROOT")" = tmpfs ]
  chown "$AGENT_USER:$AGENT_USER" "$QUOTA_ROOT"
  mkdir -p "$PROJECT_ROOT/tools" "$PROJECT_ROOT/deploy"
  install -m 0755 "$ROOT/data/export_onnx_bundle.py" "$PROJECT_ROOT/tools/export_onnx_bundle.py"
  install -m 0644 "$ROOT/data/deployment_spec.json" "$B_SPEC"
  python3 "$ROOT/data/index_refresh_worker.py" seed --project "$PROJECT_ROOT"
  chown -R "$AGENT_USER:$AGENT_USER" "$PROJECT_ROOT"
  chmod 755 "$PROJECT_ROOT" "$PROJECT_ROOT/tools" "$PROJECT_ROOT/deploy"
}

hide_a_helper() {
  chown -R root:root "$A_HELPER_ROOT" 2>/dev/null || true
  chmod -R go-rwx "$A_HELPER_ROOT" 2>/dev/null || true
}

quota_available_bytes() {
  python3 - "$QUOTA_ROOT" <<'PY'
import os, sys
st = os.statvfs(sys.argv[1])
print(st.f_bavail * st.f_frsize)
PY
}

quota_used_bytes() {
  du -sb "$PROJECT_ROOT" 2>/dev/null | awk '{print $1}'
}

progress_count() {
  [ -f "$A_PROGRESS_FILE" ] || { echo 0; return; }
  wc -l <"$A_PROGRESS_FILE"
}

capture_quota_state() {
  local label=$1 outdir=$2
  mkdir -p "$outdir"
  findmnt -T "$PROJECT_ROOT" >"$outdir/${label}.findmnt.txt" 2>&1 || true
  df -B1 "$QUOTA_ROOT" >"$outdir/${label}.quota_df.txt" 2>&1 || true
  df -B1 / >"$outdir/${label}.global_df.txt" 2>&1 || true
  du -sb "$PROJECT_ROOT" >"$outdir/${label}.project_du.txt" 2>&1 || true
  python3 - "$QUOTA_ROOT" "$PROJECT_ROOT" "$QUOTA_SOURCE" "$QUOTA_MIB" \
    >"$outdir/${label}.quota_state.json" <<'PY'
import json, os, pathlib, sys
root, project, source, quota_mib = sys.argv[1:]
st = os.statvfs(root)
root_stat = os.stat(root)
project_stat = os.stat(project)
print(json.dumps({
    "quota_source": source,
    "quota_root": root,
    "quota_mib": int(quota_mib),
    "total_bytes": st.f_blocks * st.f_frsize,
    "available_bytes": st.f_bavail * st.f_frsize,
    "quota_device": root_stat.st_dev,
    "project_device": project_stat.st_dev,
    "project_realpath": str(pathlib.Path(project).resolve()),
}, sort_keys=True))
PY
}

require_global_headroom_and_quota_pressure() {
  python3 - / "$QUOTA_ROOT" "$GLOBAL_HEADROOM_MIN_BYTES" "$B_REQUIRED_BYTES" <<'PY'
import os, sys
global_st = os.statvfs(sys.argv[1])
quota_st = os.statvfs(sys.argv[2])
global_free = global_st.f_bavail * global_st.f_frsize
quota_free = quota_st.f_bavail * quota_st.f_frsize
global_min = int(sys.argv[3])
b_required = int(sys.argv[4])
print(f"GLOBAL_FREE_BYTES={global_free} QUOTA_FREE_BYTES={quota_free} B_REQUIRED_BYTES={b_required}")
raise SystemExit(0 if global_free >= global_min and global_free > b_required and quota_free < b_required else 1)
PY
}

run_b_publish() {
  rm -rf "$B_OUTPUT" "$PROJECT_ROOT/deploy/.int8-onnx-v7.staging."*
  runuser -u "$AGENT_USER" -- env -i HOME="/home/$AGENT_USER" USER="$AGENT_USER" \
    LOGNAME="$AGENT_USER" PATH=/usr/local/bin:/usr/bin:/bin LANG=C.UTF-8 \
    python3 "$PROJECT_ROOT/tools/export_onnx_bundle.py" export --spec "$B_SPEC" --out "$B_OUTPUT"
}
