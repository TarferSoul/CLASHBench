#!/bin/bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
workers=
if [ "${1:-}" = --workers ] && [ -n "${2:-}" ]; then workers=$2; shift 2; fi
[ "$workers" = 12 ] && [ "$#" = 0 ] || {
  echo "usage: ./run_parallel_build.sh --workers 12" >&2
  exit 2
}
cgroup=$(<.pid_cgroup)
exec python3 tools/parallel_native_build.py \
  --source "$PWD" --output /work/out/native-sdk --workers "$workers" \
  --deadline 12 --cgroup "$cgroup"
