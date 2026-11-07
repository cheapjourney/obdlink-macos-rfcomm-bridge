#!/usr/bin/env bash
# Stop the bridge started by start.sh.
set -euo pipefail

RUN_DIR="${OBDLINK_RUN_DIR:-$HOME/.obdlink-bridge}"
PTY_LINK="${OBDLINK_PTY:-/tmp/obdlink}"

stopped=0
for name in socat bridge; do
  pidfile="$RUN_DIR/$name.pid"
  if [[ -f "$pidfile" ]]; then
    pid="$(cat "$pidfile")"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      stopped=1
    fi
    rm -f "$pidfile"
  fi
done

sleep 1
# Fall back to a name-based cleanup in case a pid was recycled.
pkill -f "socat PTY,link=$PTY_LINK" 2>/dev/null && stopped=1 || true
pkill -f "obdlink-rfcomm --address" 2>/dev/null && stopped=1 || true

rm -f "$PTY_LINK"

if [[ "$stopped" -eq 1 ]]; then
  echo "bridge stopped"
else
  echo "bridge was not running"
fi
