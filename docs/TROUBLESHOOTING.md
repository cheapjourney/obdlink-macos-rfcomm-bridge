# Troubleshooting

## `open()` on `/dev/cu.<adapter>` succeeds but no data arrives

Symptom: the port opens in a few milliseconds, `read()` returns nothing at any
baud rate, and `log show --predicate 'process == "bluetoothd"'` shows **no**
`Allocating ACL connection` at all.

Cause: the persisted port object macOS created at pairing time no longer
initiates connections. The adapter is fine.

Fix: use this bridge. It opens the RFCOMM channel directly and does not depend on
the persisted port.

## `openRFCOMMChannelSync` fails with `rc=0x2C0` (704)

The baseband link is up but the RFCOMM channel cannot be opened. Usual causes:

- another host (a phone app) holds the adapter's single SPP connection — close it;
- the pairing is incomplete (device missing from the system's paired list) —
  remove the device and pair again;
- the adapter is asleep — many adapters drop to a low-power state when idle.

## `baseband connection failed` (exit code 4)

The adapter is not answering paging. It is asleep, out of range, or powered off.
Wake it (button or vehicle ignition) and retry.

## `bind failed ... (port in use?)` (exit code 6)

Another process holds the TCP port. Find it with:

```bash
lsof -nP -iTCP:35100 -sTCP:LISTEN
```

Pick a different port with `--port`.

## `socat: command not found`

```bash
brew install socat
```

## macOS asks for Bluetooth permission

The first run may trigger a system prompt for Bluetooth access. Accept it, or
grant it later under **System Settings → Privacy & Security → Bluetooth**.

## Checking what the bridge is doing

```bash
tail -f ~/.obdlink-bridge/bridge.log
```

`--verbose` adds per-packet lines. The log never contains adapter traffic beyond
byte counts unless you enable verbose mode.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | clean exit |
| 2 | bad usage / invalid address |
| 3 | device not found |
| 4 | baseband connection failed |
| 5 | RFCOMM channel open failed |
| 6 | TCP bind or listen failed |
| 75 | SPP channel closed by the peer (restart the bridge) |
