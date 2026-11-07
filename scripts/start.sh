#!/usr/bin/env bash
# Start the bridge and expose it as a pseudo-terminal.
#
#   adapter --Bluetooth--> RFCOMM --obdlink-rfcomm--> 127.0.0.1:<port>
#                                                          |
#                                              socat -> $PTY_LINK
#
# Usage:
#   ./scripts/start.sh --address AA-BB-CC-DD-EE-FF [--port 35100] [--pty /tmp/obdlink]
#
# Environment equivalents: OBDLINK_ADDRESS, OBDLINK_PORT, OBDLINK_PTY, OBDLINK_CHANNEL
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$HERE/build/obdlink-rfcomm"
RUN_DIR="${OBDLINK_RUN_DIR:-$HOME/.obdlink-bridge}"
ADDRESS="${OBDLINK_ADDRESS:-}"
PORT="${OBDLINK_PORT:-35100}"
CHANNEL="${OBDLINK_CHANNEL:-1}"
PTY_LINK="${OBDLINK_PTY:-/tmp/obdlink}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--address) ADDRESS="$2"; shift 2 ;;
    -p|--port)    PORT="$2"; shift 2 ;;
    -c|--channel) CHANNEL="$2"; shift 2 ;;
    --pty)        PTY_LINK="$2"; shift 2 ;;
    -h|--help)    sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$ADDRESS" ]] || { echo "error: --address is required" >&2; exit 2; }
[[ -x "$BIN" ]] || { echo "error: $BIN not built (run make)" >&2; exit 3; }
command -v socat >/dev/null || { echo "error: socat not installed (brew install socat)" >&2; exit 3; }

mkdir -p "$RUN_DIR"
LOG="$RUN_DIR/bridge.log"

# Refuse to start twice.
if [[ -f "$RUN_DIR/bridge.pid" ]] && kill -0 "$(cat "$RUN_DIR/bridge.pid")" 2>/dev/null; then
  echo "error: bridge already running (pid $(cat "$RUN_DIR/bridge.pid"))" >&2
  exit 4
fi

: > "$LOG"
"$BIN" --address "$ADDRESS" --port "$PORT" --channel "$CHANNEL" >>"$LOG" 2>&1 &
echo $! > "$RUN_DIR/bridge.pid"

for _ in $(seq 1 40); do
  grep -q '^READY' "$LOG" 2>/dev/null && break
  if ! kill -0 "$(cat "$RUN_DIR/bridge.pid")" 2>/dev/null; then
    echo "error: bridge exited during startup:" >&2
    tail -5 "$LOG" >&2
    rm -f "$RUN_DIR/bridge.pid"
    exit 5
  fi
  sleep 0.5
done

grep -q '^READY' "$LOG" || { echo "error: bridge did not become ready" >&2; tail -5 "$LOG" >&2; exit 5; }

rm -f "$PTY_LINK"
socat "PTY,link=$PTY_LINK,raw,echo=0" "TCP:127.0.0.1:$PORT" >>"$LOG" 2>&1 &
echo $! > "$RUN_DIR/socat.pid"
sleep 1

if [[ ! -e "$PTY_LINK" ]]; then
  echo "error: PTY not created at $PTY_LINK" >&2
  exit 6
fi

echo "bridge ready"
echo "  tcp : 127.0.0.1:$PORT (loopback only)"
echo "  pty : $PTY_LINK -> $(readlink "$PTY_LINK" 2>/dev/null || echo '?')"
echo "  log : $LOG"
echo
echo "connect with pyserial:  Serial('$PTY_LINK', 115200, timeout=1)"
echo "stop with:              $HERE/scripts/stop.sh"
