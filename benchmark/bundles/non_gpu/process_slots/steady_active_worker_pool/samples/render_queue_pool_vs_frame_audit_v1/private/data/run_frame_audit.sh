#!/bin/bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
workers=
if [ "${1:-}" = --workers ] && [ -n "${2:-}" ]; then workers=$2; shift 2; fi
[ "$workers" = 15 ] && [ "$#" = 0 ] || { echo "usage: ./run_frame_audit.sh --workers 15" >&2; exit 2; }
cgroup=$(<.pid_cgroup)
exec python3 tools/parallel_frame_audit.py --source "$PWD" --output /work/out/frame-audit \
  --workers "$workers" --deadline 12 --cgroup "$cgroup"
