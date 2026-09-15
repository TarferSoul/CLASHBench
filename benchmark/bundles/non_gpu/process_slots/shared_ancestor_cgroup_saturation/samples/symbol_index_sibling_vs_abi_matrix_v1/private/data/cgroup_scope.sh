#!/usr/bin/env bash

pids_event_max() {
  local file=$1 value
  value=$(awk '$1 == "max" {print $2}' "$file" 2>/dev/null | tail -1)
  printf '%s\n' "${value:-0}"
}

leaf_pids_limit() {
  local cgroup=$1
  if [ -r "$cgroup/pids.max" ]; then
    cat "$cgroup/pids.max"
  else
    printf 'not_delegated\n'
  fi
}

move_self_to_cgroup() {
  local destination=$1
  printf '%s\n' "$BASHPID" > "$destination/${CGROUP_TASK_FILE:-cgroup.procs}"
}

_move_root_procs_to_anchor() {
  local mount=$1 anchor=$2 pass pid task_file
  mkdir -p "$anchor"
  task_file=cgroup.procs
  if [[ $(cat "$mount/cgroup.type" 2>/dev/null) == *threaded* ]]; then
    printf 'threaded\n' > "$anchor/cgroup.type"
    task_file=cgroup.threads
  fi
  for pass in 1 2 3 4 5 6; do
    mapfile -t pids < "$mount/$task_file"
    [ "${#pids[@]}" -eq 0 ] && return 0
    for pid in "${pids[@]}"; do
      [ -n "$pid" ] || continue
      printf '%s\n' "$pid" > "$anchor/$task_file" 2>/dev/null || true
    done
  done
  mapfile -t pids < "$mount/$task_file"
  [ "${#pids[@]}" -eq 0 ]
}

setup_shared_ancestor_scope() {
  : "${RUNTIME_ROOT:?}"
  : "${CGROUP_MOUNT_DIR:?}"
  : "${CGROUP_PARENT_NAME:?}"
  : "${CGROUP_A_NAME:?}"
  : "${CGROUP_B_NAME:?}"
  : "${PARENT_PIDS_MAX:?}"

  local mount controllers enabled err anchor mount_type parent_type
  mkdir -p "$CGROUP_MOUNT_DIR"
  err="$RUNTIME_ROOT/cgroup_mount.err"
  if mount -t cgroup2 -o rw,nosuid,nodev,noexec cgroup2 "$CGROUP_MOUNT_DIR" 2>"$err"; then
    mount="$CGROUP_MOUNT_DIR"
    CGROUP_PRIVATE_MOUNT=1
  else
    mount=$(findmnt -n -t cgroup2 -o TARGET | head -n1)
    CGROUP_PRIVATE_MOUNT=0
  fi

  [ -n "$mount" ] || { echo "SETUP_FAIL=CGROUP2_MOUNT_MISSING"; return 1; }
  [ "$(stat -fc %T "$mount" 2>/dev/null)" = cgroup2fs ] || {
    echo "SETUP_FAIL=CGROUP2_REQUIRED mount=$mount"; return 1;
  }
  [ -r "$mount/cgroup.controllers" ] || {
    echo "SETUP_FAIL=CGROUP_CONTROLLERS_UNREADABLE mount=$mount"; return 1;
  }
  IFS= read -r controllers < "$mount/cgroup.controllers"
  case " $controllers " in
    *" pids "*) ;;
    *) echo "SETUP_FAIL=PIDS_CONTROLLER_UNAVAILABLE controllers=$controllers"; return 1 ;;
  esac

  IFS= read -r enabled < "$mount/cgroup.subtree_control"
  if [[ " $enabled " != *" pids "* ]]; then
    if ! printf '+pids\n' > "$mount/cgroup.subtree_control" 2>/dev/null; then
      anchor="$mount/workspace-ci-anchor"
      _move_root_procs_to_anchor "$mount" "$anchor" || {
        echo "SETUP_FAIL=CGROUP_ROOT_NOT_EMPTY_FOR_PIDS"; return 1;
      }
      printf '+pids\n' > "$mount/cgroup.subtree_control" || {
        echo "SETUP_FAIL=PIDS_SUBTREE_ENABLE_FAILED"; return 1;
      }
    fi
  fi

  CGROUP_MOUNT="$mount"
  CGROUP_PARENT="$mount/$CGROUP_PARENT_NAME"
  CGROUP_A="$CGROUP_PARENT/$CGROUP_A_NAME"
  CGROUP_B="$CGROUP_PARENT/$CGROUP_B_NAME"
  rm -rf "$CGROUP_PARENT" 2>/dev/null || true
  mkdir "$CGROUP_PARENT"
  mount_type=$(cat "$mount/cgroup.type")
  CGROUP_TASK_FILE=cgroup.procs
  if [[ $mount_type == *threaded* ]]; then
    printf 'threaded\n' > "$CGROUP_PARENT/cgroup.type" || {
      echo "SETUP_FAIL=PARENT_THREADED_MODE_FAILED root_type=$mount_type"; return 1;
    }
    CGROUP_TASK_FILE=cgroup.threads
  fi
  parent_type=$(cat "$CGROUP_PARENT/cgroup.type")
  [[ $parent_type != *invalid* ]] || {
    echo "SETUP_FAIL=PARENT_CGROUP_INVALID root_type=$mount_type parent_type=$parent_type"; return 1;
  }
  [ -r "$CGROUP_PARENT/pids.max" ] || {
    echo "SETUP_FAIL=PARENT_PIDS_INTERFACE_MISSING"; return 1;
  }
  printf '%s\n' "$PARENT_PIDS_MAX" > "$CGROUP_PARENT/pids.max"

  LEAF_PIDS_DELEGATED=0
  if ! printf '+pids\n' > "$CGROUP_PARENT/cgroup.subtree_control" 2>/dev/null; then
    echo "SETUP_FAIL=LEAF_PIDS_DELEGATION_FAILED parent_type=$parent_type"; return 1
  fi
  LEAF_PIDS_DELEGATED=1
  mkdir "$CGROUP_A" "$CGROUP_B"
  if [[ $CGROUP_TASK_FILE == cgroup.threads ]]; then
    printf 'threaded\n' > "$CGROUP_A/cgroup.type"
    printf 'threaded\n' > "$CGROUP_B/cgroup.type"
  fi
  [[ $(cat "$CGROUP_A/cgroup.type") != *invalid* && $(cat "$CGROUP_B/cgroup.type") != *invalid* ]] || {
    echo "SETUP_FAIL=LEAF_CGROUP_INVALID"; return 1;
  }
  printf 'max\n' > "$CGROUP_A/pids.max"
  printf 'max\n' > "$CGROUP_B/pids.max"
  export CGROUP_PRIVATE_MOUNT CGROUP_MOUNT CGROUP_PARENT CGROUP_A CGROUP_B LEAF_PIDS_DELEGATED CGROUP_TASK_FILE
}

_kill_cgroup_tasks() {
  local cgroup=$1 pid task_file
  [ -d "$cgroup" ] || return 0
  task_file=${CGROUP_TASK_FILE:-cgroup.procs}
  if [ -w "$cgroup/cgroup.kill" ]; then
    printf '1\n' > "$cgroup/cgroup.kill" 2>/dev/null || true
  fi
  if [ -r "$cgroup/$task_file" ]; then
    while IFS= read -r pid; do
      [ -n "$pid" ] || continue
      kill "$pid" 2>/dev/null || true
    done < "$cgroup/$task_file"
  fi
}

cleanup_shared_ancestor_scope() {
  local pass task_file
  [ -n "${CGROUP_PARENT:-}" ] || return 0
  task_file=${CGROUP_TASK_FILE:-cgroup.procs}
  _kill_cgroup_tasks "${CGROUP_B:-}"
  for pass in $(seq 1 40); do
    if [ -r "${CGROUP_A:-}/$task_file" ] && [ -r "${CGROUP_B:-}/$task_file" ] && \
      [ ! -s "$CGROUP_A/$task_file" ] && [ ! -s "$CGROUP_B/$task_file" ]; then
      break
    fi
    sleep 0.05
  done
  rmdir "${CGROUP_A:-}" "${CGROUP_B:-}" 2>/dev/null || true
  if [ -d "$CGROUP_PARENT" ]; then
    printf 'max\n' > "$CGROUP_PARENT/pids.max" 2>/dev/null || true
    rmdir "$CGROUP_PARENT" 2>/dev/null || true
  fi
  if [ "${CGROUP_PRIVATE_MOUNT:-0}" = 1 ]; then
    umount "$CGROUP_MOUNT" 2>/dev/null || true
  fi
}

capture_cgroup_hierarchy() {
  local output=$1 path pid task_file
  task_file=${CGROUP_TASK_FILE:-cgroup.procs}
  {
    echo "mount=$CGROUP_MOUNT"
    echo "shared_ancestor=$CGROUP_PARENT"
    echo "a_child=$CGROUP_A"
    echo "b_child=$CGROUP_B"
    echo "leaf_pids_delegated=$LEAF_PIDS_DELEGATED"
    echo "mount_cgroup_type=$(cat "$CGROUP_MOUNT/cgroup.type" 2>/dev/null || echo missing)"
    echo "parent_cgroup_type=$(cat "$CGROUP_PARENT/cgroup.type" 2>/dev/null || echo missing)"
    echo "a_leaf_cgroup_type=$(cat "$CGROUP_A/cgroup.type" 2>/dev/null || echo missing)"
    echo "b_leaf_cgroup_type=$(cat "$CGROUP_B/cgroup.type" 2>/dev/null || echo missing)"
    echo "parent_pids_max=$(cat "$CGROUP_PARENT/pids.max" 2>/dev/null || echo missing)"
    echo "parent_pids_current=$(cat "$CGROUP_PARENT/pids.current" 2>/dev/null || echo missing)"
    echo "a_leaf_pids_max=$(leaf_pids_limit "$CGROUP_A")"
    echo "b_leaf_pids_max=$(leaf_pids_limit "$CGROUP_B")"
    echo "a_leaf_tasks=$(wc -l < "$CGROUP_A/$task_file" 2>/dev/null || echo 0)"
    echo "b_leaf_tasks=$(wc -l < "$CGROUP_B/$task_file" 2>/dev/null || echo 0)"
    echo "parent_events_begin"
    cat "$CGROUP_PARENT/pids.events" 2>/dev/null || true
    echo "parent_events_end"
    if [ -r "$CGROUP_PARENT/pids.events.local" ]; then
      echo "parent_events_local_begin"
      cat "$CGROUP_PARENT/pids.events.local"
      echo "parent_events_local_end"
    fi
    for path in "$CGROUP_A/$task_file" "$CGROUP_B/$task_file"; do
      echo "cgroup_tasks=$path"
      while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        [ -r "/proc/$pid/cgroup" ] || continue
        printf 'pid=%s cgroup=' "$pid"
        tr '\n' ';' < "/proc/$pid/cgroup"
        echo
      done < "$path"
    done
  } > "$output"
}
