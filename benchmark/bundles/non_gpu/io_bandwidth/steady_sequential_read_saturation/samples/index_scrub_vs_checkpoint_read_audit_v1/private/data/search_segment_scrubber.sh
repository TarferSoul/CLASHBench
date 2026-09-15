#!/usr/bin/env bash
set -Eeuo pipefail

: "${A_SEGMENT_ROOT:?}"
: "${A_STATE_ROOT:?}"
: "${A_CATALOG:?}"
: "${A_READER_WORKERS:?}"
: "${DIRECT_BLOCK_BYTES:?}"

export LC_ALL=C
umask 077
mkdir -p "$A_STATE_ROOT"
status_file="$A_STATE_ROOT/status.tsv"
history_file="$A_STATE_ROOT/verified.tsv"
: >"$history_file"
active_pids=()

cleanup_children() {
  local pid
  for pid in "${active_pids[@]:-}"; do
    kill "$pid" 2>/dev/null || true
  done
}
trap 'cleanup_children; exit 0' TERM INT
trap cleanup_children EXIT

verified_total=0
verified_bytes=0
cycle=0
failures=0

publish_status() {
  local phase=$1 current=$2 workers=${3:-none}
  local tmp="$status_file.tmp.$$"
  {
    printf 'phase\t%s\n' "$phase"
    printf 'current_segments\t%s\n' "$current"
    printf 'reader_pids\t%s\n' "$workers"
    printf 'verified_total\t%s\n' "$verified_total"
    printf 'verified_bytes\t%s\n' "$verified_bytes"
    printf 'cycle\t%s\n' "$cycle"
    printf 'failures\t%s\n' "$failures"
    printf 'updated_epoch\t%s\n' "$(date +%s)"
  } >"$tmp"
  mv "$tmp" "$status_file"
}

sentinel_ok() {
  local input=$1 prefix=$2 offset=${3:-0}
  local text
  if [ "$offset" -eq 0 ]; then
    text=$(dd if="$input" bs=128 count=1 status=none 2>/dev/null | tr -d '\000' | head -c 128)
  else
    text=$(dd if="$input" bs=1 skip="$offset" count=128 status=none 2>/dev/null | tr -d '\000' | head -c 128)
  fi
  case "$text" in "$prefix"*) return 0 ;; *) return 1 ;; esac
}

read_segment() {
  local name=$1 expected_bytes=$2 index=$3 result=$4
  local input="$A_SEGMENT_ROOT/$name"
  local receipt="$A_STATE_ROOT/read.$BASHPID.$index.txt"
  local direct_bytes footer_offset rc=0
  footer_offset=$((expected_bytes - 4096))
  dd if="$input" of=/dev/null iflag=direct,fullblock bs="$DIRECT_BLOCK_BYTES" > /dev/null 2>"$receipt" || rc=$?
  direct_bytes=$(awk '/ bytes .* copied/ {print $1; exit}' "$receipt")
  direct_bytes=${direct_bytes:-0}
  header_ok=0
  footer_ok=0
  sentinel_ok "$input" SEARCH_SEGMENT_HEADER_ 0 && header_ok=1
  sentinel_ok "$input" SEARCH_SEGMENT_FOOTER_ "$footer_offset" && footer_ok=1
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$name" "$expected_bytes" "$direct_bytes" "$header_ok" "$footer_ok" "$rc" >"$result"
  rm -f "$receipt"
}

publish_status starting none none
while :; do
  cycle=$((cycle + 1))
  batch="$A_STATE_ROOT/batch.$$.$cycle"
  rm -rf "$batch"
  mkdir -p "$batch"
  active_pids=()
  names=()
  index=0
  while IFS=$'\t' read -r name expected_bytes header footer; do
    read_segment "$name" "$expected_bytes" "$index" "$batch/result.$index" &
    active_pids+=("$!")
    names+=("$name")
    index=$((index + 1))
    if [ "${#active_pids[@]}" -ge "$A_READER_WORKERS" ]; then
      break
    fi
  done <"$A_CATALOG"
  worker_csv=$(IFS=,; printf '%s' "${active_pids[*]}")
  name_csv=$(IFS=,; printf '%s' "${names[*]}")
  publish_status reading "$name_csv" "$worker_csv"

  failed=0
  for pid in "${active_pids[@]}"; do
    if ! wait "$pid"; then
      failed=1
    fi
  done
  active_pids=()
  if [ "$failed" -ne 0 ]; then
    failures=$((failures + 1))
    publish_status failed "$name_csv" none
    exit 31
  fi

  for result in $(find "$batch" -maxdepth 1 -type f -name 'result.*' | sort -t. -k2,2n); do
    IFS=$'\t' read -r name expected_bytes direct_bytes header_ok footer_ok rc <"$result"
    if [ "$rc" != 0 ] || [ "$direct_bytes" != "$expected_bytes" ] || [ "$header_ok" != 1 ] || [ "$footer_ok" != 1 ]; then
      failures=$((failures + 1))
      publish_status failed "$name" none
      exit 32
    fi
    verified_total=$((verified_total + 1))
    verified_bytes=$((verified_bytes + expected_bytes))
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s%N)" "$cycle" "$name" "$expected_bytes" "$direct_bytes" >>"$history_file"
  done
  rm -rf "$batch"
  publish_status verified "$name_csv" none
done
