#!/usr/bin/env bash
# Connectivity check against a real adapter.
#
# Starts the bridge, sends a single local AT command (ATI - adapter identity,
# which never reaches a vehicle bus), checks the reply, and stops the bridge.
#
#   ./scripts/verify.sh --address AA-BB-CC-DD-EE-FF [--port 35100]
#
# Uses only python3 stdlib on the client side; no pyserial required.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADDRESS="${OBDLINK_ADDRESS:-}"
PORT="${OBDLINK_PORT:-35100}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--address) ADDRESS="$2"; shift 2 ;;
    -p|--port)    PORT="$2"; shift 2 ;;
    -h|--help)    sed -n '2,10p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$ADDRESS" ]] || { echo "error: --address is required" >&2; exit 2; }
command -v python3 >/dev/null || { echo "error: python3 not found" >&2; exit 3; }

cleanup() { "$HERE/scripts/stop.sh" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "== starting bridge =="
"$HERE/scripts/start.sh" --address "$ADDRESS" --port "$PORT" || {
  echo "RESULT: FAIL (bridge did not start)" >&2
  exit 1
}

echo
echo "== ATI (adapter identity, no vehicle bus involved) =="
python3 - "$PORT" <<'PY'
import socket, sys, time

port = int(sys.argv[1])
try:
    sock = socket.create_connection(("127.0.0.1", port), timeout=5)
except OSError as exc:
    print(f"could not connect to 127.0.0.1:{port}: {exc}")
    sys.exit(1)

sock.settimeout(3)
sock.sendall(b"ATI\r")
reply = b""
deadline = time.monotonic() + 3
while time.monotonic() < deadline:
    try:
        chunk = sock.recv(128)
    except socket.timeout:
        break
    if not chunk:
        break
    reply += chunk
    if reply.endswith(b">"):
        break
sock.close()

text = reply.decode("ascii", errors="replace").strip()
print(f"raw reply: {text!r}")
ok = reply.endswith(b">") and b"\r" in reply
print("RESULT:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
PY
