# obdlink-macos-rfcomm-bridge

Expose a Bluetooth SPP adapter (OBDLink MX+, STN-based, ELM327-compatible) as a
loopback TCP socket and a pseudo-terminal on macOS — without relying on the
`/dev/cu.*` device that macOS creates for it.

```
adapter --Bluetooth--> RFCOMM --obdlink-rfcomm--> 127.0.0.1:35100 --> socat PTY --> /tmp/obdlink
```

## Why this exists

macOS creates a persistent `/dev/cu.<DeviceName>-SerialPort` node for a paired
classic-Bluetooth SPP device. In practice that node can stop working after the
first session: `open()` returns a file descriptor in milliseconds, `read()`
returns nothing, and `bluetoothd` never logs a connection attempt — no ACL
request, no RFCOMM request, nothing. The device itself is fine (it answers
normally over RFCOMM), but the persisted port object no longer initiates
connections.

`obdlink-rfcomm` bypasses that layer. It opens the RFCOMM channel directly
through `IOBluetooth`, keeps it open, and relays bytes to a TCP socket bound to
`127.0.0.1`. A small `socat` PTY then makes the byte stream look like an ordinary
serial device, so existing `pyserial` code works unchanged.

## Requirements

- macOS 10.13 or newer (developed on 12.7.6, Intel)
- Xcode Command Line Tools (`xcode-select --install`) for `swiftc`
- `socat` for the PTY layer (`brew install socat`)
- The adapter paired with the Mac through **System Settings → Bluetooth**

Pairing is manual by design. Most adapters only become discoverable after you
press their physical pairing button and hold it until the LED blinks quickly.

### Tested environment

Everything in the "Test results" section below was measured on exactly this setup:

| Component | Version |
|---|---|
| macOS | 12.7.6 (build 21H1320) |
| Hardware | Intel Mac, x86_64 |
| Adapter | OBDLink MX+ (STN2255, firmware v5.10.3) |
| Link | classic Bluetooth 3.0 SPP, RFCOMM channel 1 |

Other macOS releases, Apple Silicon Macs and other SPP adapters are expected to
work because the code only uses public `IOBluetooth` APIs — but they are
**untested**. Please open an issue with your versions if you try one.

## Build

```bash
make            # builds build/obdlink-rfcomm
make test       # runs the hardware-free self-test
```

Or directly:

```bash
swiftc -O Sources/obdlink-rfcomm/main.swift -o build/obdlink-rfcomm
```

## Usage

### 1. Bridge only (TCP)

```bash
./build/obdlink-rfcomm --address AA-BB-CC-DD-EE-FF
# READY 127.0.0.1:35100
```

Options:

| Flag | Default | Meaning |
|---|---|---|
| `-a, --address` | `$OBDLINK_ADDRESS` | Bluetooth address, `AA-BB-CC-DD-EE-FF` or colon-separated |
| `-p, --port` | `35100` | TCP port, bound to `127.0.0.1` only |
| `-c, --channel` | `1` | RFCOMM channel from the device's SDP record |
| `-v, --verbose` | off | log per-packet detail to stderr |
| `--self-test` | — | run loopback tests without Bluetooth |

### 2. Bridge + pseudo-terminal (recommended)

```bash
./scripts/start.sh --address AA-BB-CC-DD-EE-FF
# bridge ready
#   tcp : 127.0.0.1:35100 (loopback only)
#   pty : /tmp/obdlink -> /dev/ttys004
```

Then talk to it like any serial port:

```python
import serial

with serial.Serial("/tmp/obdlink", 115200, timeout=1) as port:
    port.write(b"ATI\r")
    print(port.read(64))     # b'ATI\rELM327 v1.4b\r\r>'
```

Stop it:

```bash
./scripts/stop.sh
```

### 3. Verify the connection

```bash
./scripts/verify.sh --address AA-BB-CC-DD-EE-FF
```

Starts the bridge, sends a single `ATI` (adapter identity — this never reaches a
vehicle bus), checks for the `>` prompt, and stops the bridge again. Exit code 0
means the adapter answered.

## Scope — read this before using it

This project is a **transport**, nothing more. It moves bytes between a Bluetooth
SPP adapter and a local TCP socket / PTY.

- **The link is bidirectional.** Any client that connects can send whatever it
  wants, including vehicle commands. Treat access to the TCP port as equivalent
  to physical access to the OBD connector.
- **It is not a diagnostic tool**, not a CAN/UDS library, and **not a safety
  filter**. It does not parse, validate or allowlist anything.
- **No vehicle traffic was used in testing.** The only bytes ever sent through
  this bridge during development were `ATI`, the adapter's own identity query.
  No CAN request, no UDS/KWP request, no coding, no ECU write was tested with
  this release — and none is claimed to work.
- **CarPlay and Android Auto are not part of this project** in any form.

If you need a client that can only issue a fixed set of read requests, enforce
that in the client. This bridge will not do it for you.

## How it works

1. `IOBluetoothDevice(addressString:)` finds the paired device.
2. `openConnection()` brings up the baseband link if it is down.
3. `openRFCOMMChannelSync(withChannelID:delegate:)` opens the SPP channel.
4. A background thread accepts one TCP client at a time and relays bytes
   bidirectionally: RFCOMM delegate → client socket, client socket → `writeSync`.
5. When the client disconnects the RFCOMM channel stays open, so the next client
   connects without any Bluetooth round trip.

## Security model

- The TCP listener binds **`127.0.0.1` only**. It is not reachable from the LAN.
- One client at a time; a second connection waits until the first closes.
- No credentials, no pairing state, and no device addresses are stored by this
  program. The address is supplied at runtime.
- The program does not send anything on its own. Whatever reaches the adapter is
  exactly what the client wrote — see **Scope** above: that is a transport
  property, not a safety guarantee.

## Self-test

`--self-test` exercises the whole TCP path with no Bluetooth hardware and no
serial port:

```
PASS  listener binds  [port 49721]
PASS  bound to 127.0.0.1 only  [127.0.0.1]
PASS  client connects
PASS  accept returns a socket
PASS  peer address is loopback  [127.0.0.1:49722]
PASS  client -> bridge write
PASS  bridge receives payload  [ATI\r]
PASS  client receives payload  [ELM327 v1.4b\r\r>]
PASS  port released after close  [re-bound 49721]

9 passed, 0 failed
```

It verifies bind scope, accept, bidirectional relay, and that the port is
released afterwards.

## Test results

Two different things — do not read the second as a guarantee for your hardware.

### Offline tests (no Bluetooth, repeatable on any machine)

The self-test above is nine checks of the TCP path: bind scope, accept, loopback
peer, bidirectional relay, port release. It needs no adapter and no paired
device, so it is reproducible everywhere. Result on the tested environment:
**9 passed, 0 failed**.

### Live stability (measured once, on the hardware listed above)

| Test | Result |
|---|---|
| Continuous session held open | **300 s**, 30 polls at 10 s intervals, 0 timeouts, 0 drops |
| Adapter identification during the session | 30/30 `ATI` answered (`ELM327 v1.4b`) |
| Open/close cycles through the PTY | **10/10** reconnect without a Bluetooth re-connect |

The RFCOMM channel stays open across client reconnects; only the PTY/socket
client comes and goes. `STI` on the same adapter reported `STN2255 v5.10.3`.

These numbers come from a single measurement on one unit. They show that the
approach works end to end; they are not a promise about throughput, latency or
long-term stability on other adapters or macOS versions.

### Live verification of this build (v0.1.0)

`scripts/verify.sh` sends exactly one command — `ATI`, the adapter's own identity
query, which never reaches a vehicle bus — and was run twice against the same
adapter with this binary:

| Run | Result |
|---|---|
| 1 | **PASS** — fresh RFCOMM channel opened, reply `ATI\rELM327 v1.4b\r\r>` |
| 2 | **PASS** — same reply after the first session had been fully closed |

After each run: no bridge process, no listener on `127.0.0.1:35100`, no PTY left
behind. The second run re-opened the baseband link and the RFCOMM channel from
scratch, so a clean reconnect is confirmed.

## Troubleshooting

See [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for the stale `/dev/cu`
symptom, permission prompts, port conflicts and exit codes.

## License

MIT — see [LICENSE](LICENSE).

## v0.2.0 — secured mode and hardening

The secured Unix-socket mode is the recommended path:

```
obdlink-rfcomm --unix-socket ~/.smart453/obd-bridge.sock --mode vehicle-readonly \
               --vehicle-token <token> --address AA-BB-CC-DD-EE-FF
```

It speaks NDJSON v1 (see `docs/NDJSON.md`), gates every command against a
vehicle-specific allowlist (`docs/ALLOWLIST.md`) and never starts the raw TCP relay.

**Breaking change:** the legacy TCP/PTY relay now requires `--tcp`. Without it the
bridge exits 2. The relay has no command gate and serves one client at a time.

Socket rules: `0600` inside a `0700` directory, `flock` against a second instance
(exit 7), and the path is refused if it is not a socket owned by the current user
(exit 8). Cleanup removes only the socket this process created.

Self-test: `make build && ./build/obdlink-rfcomm --self-test` (22 checks).
