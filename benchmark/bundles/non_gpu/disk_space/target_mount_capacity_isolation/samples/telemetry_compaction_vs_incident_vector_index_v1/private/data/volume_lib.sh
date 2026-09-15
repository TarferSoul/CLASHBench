#!/usr/bin/env bash

prepare_volume() {
  rm -f "$VOLUME_ROOT"
  rm -rf "$REAL_VOLUME_ROOT"
  mkdir -p "$REAL_VOLUME_ROOT"
  ln -s "$REAL_VOLUME_ROOT" "$VOLUME_ROOT"
  chown "$SERVICE_USER:$(id -gn "$SERVICE_USER")" "$REAL_VOLUME_ROOT"
  chmod 0755 "$REAL_VOLUME_ROOT"
  findmnt -T "$VOLUME_ROOT" -n -o TARGET,FSTYPE,SOURCE,OPTIONS
}

cleanup_volume() {
  rm -f "$VOLUME_ROOT"
  rm -rf "$REAL_VOLUME_ROOT"
}
