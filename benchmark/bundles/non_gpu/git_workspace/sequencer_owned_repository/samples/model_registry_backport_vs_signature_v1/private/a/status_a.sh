#!/usr/bin/env bash
set -euo pipefail

ROOT=${CASE_PRIVATE_ROOT:?set CASE_PRIVATE_ROOT}
. "$ROOT/fixture.env"

for _ in $(seq 1 60); do
  if [ -s "$A_PID_FILE" ] && [ -s "$A_STATUS_FILE" ]; then
    pid=$(cat "$A_PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      generation=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["generation"])' "$A_STATUS_FILE")
      test_rc=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["test_rc"])' "$A_STATUS_FILE")
      if [ "$generation" -ge 2 ] && [ "$test_rc" -eq 0 ]; then
        sleep 0.35
        next_generation=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["generation"])' "$A_STATUS_FILE")
        if [ "$next_generation" -gt "$generation" ]; then
          git_dir=$(git -C "$CANONICAL_REPO" rev-parse --absolute-git-dir)
          test -f "$git_dir/CHERRY_PICK_HEAD"
          test -d "$git_dir/sequencer"
          test -z "$(git -C "$CANONICAL_REPO" ls-files -u)"
          head=$(git -C "$CANONICAL_REPO" rev-parse HEAD)
          cherry_pick_head=$(cat "$git_dir/CHERRY_PICK_HEAD")
          index_tree=$(git -C "$CANONICAL_REPO" write-tree)
          echo "A_READY=1 worker_pid=$pid generation=$next_generation branch=$A_BRANCH head=$head cherry_pick_head=$cherry_pick_head index_tree=$index_tree focused_test_rc=0 sequencer_active=1"
          exit 0
        fi
      fi
    fi
  fi
  sleep 0.1
done

echo "A_READY=0 qualification_checkpoint_not_healthy" >&2
exit 1
