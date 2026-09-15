#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
. "$ROOT/fixture.env"
show_config() {
  if [ -f "$LINK_MODE_PATH" ] && grep -qx userspace_token_bucket "$LINK_MODE_PATH"; then
    cat "$A_RUNTIME_ROOT/link.config"
  else
    tc qdisc show dev "$LINK_DEVICE"
    tc class show dev "$LINK_DEVICE"
    tc filter show dev "$LINK_DEVICE" parent 1:
  fi
}
try_kernel_qdisc() {
  local error_log="$A_RUNTIME_ROOT/kernel_qdisc_error.log"
  : >"$error_log"
  tc qdisc replace dev "$LINK_DEVICE" root handle 1: htb default 20 2>>"$error_log" || return $?
  tc class replace dev "$LINK_DEVICE" parent 1: classid 1:1 htb rate 1000mbit ceil 1000mbit 2>>"$error_log" || return $?
  tc class replace dev "$LINK_DEVICE" parent 1:1 classid 1:10 htb rate "$LINK_RATE" ceil "$LINK_RATE" burst 64k cburst 64k 2>>"$error_log" || return $?
  tc class replace dev "$LINK_DEVICE" parent 1:1 classid 1:20 htb rate 1000mbit ceil 1000mbit burst 1m cburst 1m 2>>"$error_log" || return $?
  tc qdisc replace dev "$LINK_DEVICE" parent 1:10 handle 10: pfifo limit "$LINK_FIFO_PACKETS" 2>>"$error_log" || return $?
  tc qdisc replace dev "$LINK_DEVICE" parent 1:20 handle 20: pfifo limit 1000 2>>"$error_log" || return $?
  tc filter replace dev "$LINK_DEVICE" protocol ip parent 1: prio 1 u32 match ip protocol 17 0xff match ip dst "$LINK_HOST/32" match ip dport "$LINK_PORT" 0xffff flowid 1:10 2>>"$error_log" || return $?
  tc filter replace dev "$LINK_DEVICE" protocol ip parent 1: prio 2 u32 match ip protocol 6 0xff match ip src "$LINK_HOST/32" match ip sport "$LINK_PORT" 0xffff flowid 1:10 2>>"$error_log" || return $?
  printf '%s\n' kernel_qdisc >"$LINK_MODE_PATH"
}
setup_userspace_budget() {
  printf '%s\n' userspace_token_bucket >"$LINK_MODE_PATH"
  python3 "$LINK_BUDGET_PROGRAM" init \
    --path "$LINK_BUDGET_PATH" \
    --rate-bps "$((LINK_RATE_MBIT * 1000000))" \
    --capacity-bytes "$((UDP_PACKET_BYTES * LINK_FIFO_PACKETS))"
  chown "$SERVICE_UID:$SERVICE_GID" "$LINK_BUDGET_PATH" "$LINK_BUDGET_PATH.lock"
  cat >"$A_RUNTIME_ROOT/link.config" <<EOF
mode=userspace_token_bucket
device=$LINK_DEVICE
host=$LINK_HOST
port=$LINK_PORT
rate_bps=$((LINK_RATE_MBIT * 1000000))
capacity_bytes=$((UDP_PACKET_BYTES * LINK_FIFO_PACKETS))
EOF
  chmod 600 "$LINK_MODE_PATH" "$A_RUNTIME_ROOT/link.config"
}
case "${1:-}" in
  up)
    ip link set lo up 2>/dev/null || true
    mkdir -p "$A_RUNTIME_ROOT"
    rm -f "$LINK_MODE_PATH" "$A_RUNTIME_ROOT/link.config"
    if try_kernel_qdisc; then
      show_config >"$A_RUNTIME_ROOT/link.config"
      chmod 600 "$A_RUNTIME_ROOT/link.config"
    else
      tc qdisc del dev "$LINK_DEVICE" root >/dev/null 2>&1 || true
      setup_userspace_budget
    fi
    ;;
  fingerprint) show_config | sha256sum | awk '{print $1}' ;;
  show) show_config ;;
  down)
    if [ -f "$LINK_MODE_PATH" ] && grep -qx userspace_token_bucket "$LINK_MODE_PATH"; then
      rm -f "$LINK_MODE_PATH" "$LINK_BUDGET_PATH" "$LINK_BUDGET_PATH.lock" "$A_RUNTIME_ROOT/link.config"
    elif tc qdisc show dev "$LINK_DEVICE" | grep -q '^qdisc htb 1:'; then
      tc qdisc del dev "$LINK_DEVICE" root
    fi
    ;;
  *) echo "usage: $0 up|fingerprint|show|down" >&2; exit 2 ;;
esac
