# obdlink-macos-rfcomm-bridge

Expose a Bluetooth SPP adapter (OBDLink MX+, STN-based, ELM327-compatible) on
macOS without relying on the persisted `/dev/cu.*` device. The bridge has two
separate operating paths:

- a secured Unix-domain socket speaking newline-delimited JSON (recommended
  since v0.2.0), and
- the legacy loopback TCP/PTY relay, which is available only with the explicit
  `--tcp` opt-in and has no command gate.

The legacy transport looks like this:

```
adapter --Bluetooth--> RFCOMM --obdlink-rfcomm--> 127.0.0.1:35100 --> socat PTY --> /tmp/obdlink
```

The secured path does not start the TCP listener:

```
adapter --Bluetooth--> RFCOMM --obdlink-rfcomm--> Unix socket + NDJSON v1
```

## Why this exists

macOS creates a persistent `/dev/cu.<DeviceName>-SerialPort` node for a paired
classic-Bluetooth SPP device. In practice that node can stop working after the
first session: `open()` returns a file descriptor in milliseconds, `read()`
returns nothing, and `bluetoothd` never logs a connection attempt. The device is
fine and answers normally over RFCOMM, but the persisted port object no longer
initiates connections.

`obdlink-rfcomm` bypasses that layer. It opens the RFCOMM channel directly
through `IOBluetooth`, keeps it open, and relays bytes to either the secured
Unix socket or the opt-in legacy TCP/PTY path.

## Requirements

- macOS 10.13 or newer (developed on 12.7.6, Intel)
- Xcode Command Line Tools (`xcode-select --install`) for `swiftc`
- `socat` only if you use the legacy TCP/PTY path (`brew install socat`)
- The adapter paired with the Mac through **System Settings → Bluetooth**

Pairing is manual by design. Most adapters become discoverable only after you
press their physical pairing button and hold it until the LED blinks quickly.

### Tested environment

The hardware and adapter results below were measured on exactly this setup:

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

A direct build must include every Swift source file, not only `main.swift`:

```bash
swiftc -O Sources/obdlink-rfcomm/*.swift -o build/obdlink-rfcomm
```

## Modes and usage

### Secured Unix socket (recommended since v0.2.0)

```bash
./build/obdlink-rfcomm \
  --unix-socket ~/.smart453/obd-bridge.sock \
  --mode vehicle-readonly \
  --vehicle-token "$SMART453_VEHICLE_TOKEN" \
  --address AA-BB-CC-DD-EE-FF
```

The socket speaks NDJSON v1. It uses a server-side command gate and never starts
the legacy TCP listener. The mode is fixed for the process lifetime; it cannot
be upgraded by a later client message.

| Mode | Purpose | Diagnostic reads |
|---|---|---|
| `adapter-only` | Adapter identity and formatting only | blocked |
| `vehicle-readonly` | Adapter setup plus the vehicle-specific read allowlist | only the allowlist |
| `simulation` | Hardware-free fake adapter for tests | blocked (adapter-only wire mode) |

The allowlist is a **Smart 453-specific profile** documented in
[`docs/ALLOWLIST.md`](docs/ALLOWLIST.md), not a universal safety filter. The
`vehicle-readonly` mode also requires a matching `vehicle_token`; the token is a
local client check, not a signature or a remote authentication scheme.

Socket rules: `0600` inside a `0700` directory, `flock` against a second
instance (exit 7), and a path that is not a socket owned by the current user is
refused (exit 8). Cleanup removes only the socket this process created.

### Legacy TCP/PTY relay (v0.1.0-compatible; requires `--tcp`)

The raw relay is **off by default** since v0.2.0. It has no command gate and
must be enabled explicitly:

```bash
./build/obdlink-rfcomm --tcp --address AA-BB-CC-DD-EE-FF
# READY 127.0.0.1:35100
```

The listener binds `127.0.0.1` only and serves one client at a time. A second
client is rejected; it does not displace the first. Treat any client that can
reach this port as having physical access to the OBD connector.

The legacy TCP/PTY helper scripts are retained for v0.1.0 compatibility:
`scripts/start.sh` now passes `--tcp` explicitly, and `scripts/verify.sh` uses
that helper. They remain a raw, un-gated legacy path; the secured Unix-socket
mode is the recommended operating mode and is not started by these helpers.

Options:

| Flag | Default | Meaning |
|---|---|---|
| `-a, --address` | `$OBDLINK_ADDRESS` | Bluetooth address, `AA-BB-CC-DD-EE-FF` or colon-separated |
| `-p, --port` | `35100` | TCP port, bound to `127.0.0.1` only |
| `-c, --channel` | `1` | RFCOMM channel from the device's SDP record |
| `--tcp` | off | enable the legacy raw TCP/PTY relay |
| `--unix-socket` | — | use the secured NDJSON Unix socket instead of TCP |
| `--mode` | `adapter-only` | secured mode: `simulation`, `adapter-only`, `vehicle-readonly` |
| `--vehicle-token` | — | required in `vehicle-readonly` |
| `--simulate` | — | simulation mode; fake adapter, no Bluetooth |
| `--simulate-transport` | — | test-only fake transport with the real gate |
| `-v, --verbose` | off | log per-packet detail to stderr |
| `--self-test` | — | run loopback/TCP and lifecycle tests without Bluetooth |

The default mode is not a default vehicle session: without `--unix-socket`,
`--tcp` or `--self-test`, the process does not start a usable transport and
exits 2.

## Scope and security boundaries

The two paths have different security properties and must not be conflated.

### Legacy TCP/PTY path

- It is a **raw bidirectional transport**. It does not parse, validate, filter
  or allowlist commands.
- It is opt-in with `--tcp`; without that flag it does not start.
- The listener is loopback-only and accepts one client at a time.
- The adapter receives exactly what the client writes. There is no command gate,
  no diagnostic parser and no ECU write protection on this path.
- CarPlay and Android Auto are not part of this project.

### Secured Unix-socket path

- `adapter-only` permits only adapter identity and formatting commands; `21`/`22`
  diagnostic requests and protocol/addressing configuration are blocked.
- `vehicle-readonly` permits adapter setup plus the ten entries in
  [`docs/ALLOWLIST.md`](docs/ALLOWLIST.md), and `300000` as the only flow-control
  frame. Session, reset, DTC-clear, write, security-access, routine and
  memory/flash services are outside the gate.
- The gate is server-side in the bridge. It is a narrow command filter, not a
  diagnostic stack, an ECU firewall, a functional safety proof or a universal
  vehicle-security product.
- The vehicle profile is specific to the tested Smart 453 EMM/headunit
  combination. It does not establish compatibility with another vehicle,
  firmware or adapter.

The bridge does not reassemble ISO-TP. That is done by the Python diagnostic
client, which must also enforce its own gate. The bridge does not interpret
diagnostic responses.

## How it works

1. `IOBluetoothDevice(addressString:)` finds the paired device.
2. `openConnection()` brings up the baseband link if it is down.
3. `openRFCOMMChannelSync(withChannelID:delegate:)` opens the SPP channel.
4. In the secured path, a Unix socket accepts one client at a time and speaks
   NDJSON v1. In the legacy path, a background thread accepts one TCP client and
   relays bytes bidirectionally.
5. The RFCOMM channel stays open across client disconnects; only the local
   socket/PTY client comes and goes.

Terminal behaviour on the legacy path: the second client is rejected, not queued.

## Self-test

`--self-test` exercises the transport and socket lifecycle without Bluetooth
hardware or a serial port. The current v0.2.0 baseline is **23/23 checks**:
TCP bind/accept/relay/port release, line-buffer handling for real MX+ bursts and
split multi-frame answers, and the secured socket lifecycle (directory 0700,
second-instance lock, stale/live socket, regular file/symlink refusal,
permissions and ownership-aware cleanup).

The historical v0.1.0 self-test had **9/9 checks** and covered only the TCP path.
That number is not the v0.2.0 baseline.

## Test results

### MacBook offline suites (external, hardware-free)

These results were produced on the MacBook build of this candidate; they are not
a local run on the iMac:

| Suite | Result |
|---|---|
| Swift self-test | **23/23** |
| Lifecycle regression | **15/15** |
| Golden messages | **29/29** |
| Python bridge integration | **22/22** |
| Python parser/decoder | **63/63** |

The GitHub Actions workflow is a separate, narrower check. It builds Debug and
Release on `macos-latest`, runs the Swift self-test in both builds, and verifies
that the legacy path refuses to start without `--tcp`. It does **not** run the
lifecycle, golden, Python bridge or parser/decoder suites. A green CI badge is
not evidence that all five suites ran there.

### Limited vehicle validation (2026-11-09, read-only)

One deliberately limited smoke test was performed on the bridge commit
`da9dc65` with the OBDLink MX+ / STN2255 adapter. The tested binary SHA-256 was
`f751706a4938d11eaf0911340e35b2cc140e2dbe8982a64f1abc8488006641df`.

Confirmed:

- EMM `21 80`: 26-byte response, byte-identical to the earlier baseline.
- EMM `21 07`: 3-byte response (`61 07 00`), byte-identical to the earlier
  baseline.
- Headunit `21 80`: 26-byte response, byte-identical to the historical
  baseline.
- Headunit `22 F1 87`: 13-byte identity response, byte-identical to the
  historical baseline.
- Headunit `22 6C 1C`: 4-byte response (`62 6C 1C 78`), unchanged from the
  historical read-back.

No session request, no write, no configuration change and no routine/security
access was performed. The vehicle configuration was not modified.

The test is **not** a general compatibility or functional test. It covers only
the listed reads, that adapter and that commit. Other services, sessions,
writes, multimedia CAN, other adapters, other firmware and other vehicles are
untested.

An initial harness run had a client-side response-synchronisation error: a
`21 07` request was sent with the default header to `0x7E0` and was answered
negatively with `7E8 03 7F 21 12`. That read-only attempt changed nothing. The
harness was corrected to use the intended header, and the successful
measurements above were taken after that correction.

### Historical v0.1.0 live stability

The v0.1.0 release measured 300 s continuous session, 30/30 `ATI` polls and
10/10 PTY open/close cycles on one OBDLink MX+ unit. These were single-unit
transport measurements, not a guarantee for other hardware or a vehicle
compatibility claim.

## Troubleshooting

See [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) for the stale `/dev/cu`
symptom, permission prompts, port conflicts and exit codes.

## License

MIT — see [`LICENSE`](LICENSE).
