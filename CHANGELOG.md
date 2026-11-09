# Changelog

All notable changes to this project are documented here.
This project follows [Semantic Versioning](https://semver.org/).

## [0.2.0] — 2026-11-09 (candidate, not tagged)

### Added
- Secured Unix-socket mode with NDJSON v1 and a two-mode command gate.
- Deterministic NDJSON errors: `invalid json` and `message too long` are answered,
  not silent.
- Socket lifecycle: flock (exit 7), path type check (exit 8), inode-checked cleanup,
  directory never chmod'ed after creation.
- 10 additional self-test checks for the secured mode (22 total).

### Changed
- Legacy TCP/PTY relay is opt-in via `--tcp` (breaking; no gate on that path).
- Legacy relay rejects a second concurrent client instead of displacing the first.

### Security
- A second instance can no longer delete a running instance's socket.
- Regular files and symlinks at the socket path are refused, never deleted or followed.

### Known gaps
- No correlation IDs or timestamps in NDJSON v1; one request at a time.
- `blocked` carries free-text reason, no error code.
- Allowlist is vehicle-specific.
- Byte-identical builds not proven with Swift 5.7.2.

## [0.1.0] - 2026-11-07

First public release.

### Added
- `obdlink-rfcomm`: Swift bridge that opens a Bluetooth SPP channel through
  `IOBluetooth` and relays it to a TCP socket bound to `127.0.0.1`.
- One client at a time; the RFCOMM channel stays open across client reconnects.
- Command-line configuration for device address, TCP port and RFCOMM channel,
  with `OBDLINK_ADDRESS`, `OBDLINK_PORT`, `OBDLINK_CHANNEL` environment fallbacks.
- `--self-test`: hardware-free verification of bind scope, accept, bidirectional
  relay and port release (9 checks).
- `scripts/start.sh` / `scripts/stop.sh`: bridge plus `socat` PTY, pidfile-based,
  with a duplicate-start guard.
- `scripts/verify.sh`: end-to-end connectivity check that sends one local `ATI`
  and verifies the prompt, then stops the bridge.
- `docs/TROUBLESHOOTING.md`: stale `/dev/cu` symptom, RFCOMM error codes,
  permission prompts, port conflicts, exit codes.
- MIT license.

### Verified
- Offline self-test: **9/9** checks passing (TCP path only, no Bluetooth).
- Live verification with `scripts/verify.sh`, two consecutive runs against the
  same OBDLink MX+: both **PASS** (`ATI` → `ELM327 v1.4b`), second run on a
  freshly opened RFCOMM channel; no processes, listeners or PTY left behind.
- Live stability, measured once on macOS 12.7.6 (Intel x86_64) with an
  OBDLink MX+ (STN2255, firmware v5.10.3): 300 s session held open, 30/30 ATI
  polls answered, 10/10 open/close cycles through the PTY. Single measurement,
  not a guarantee for other hardware.

### Notes
- Contains no vendor code, no firmware, no vehicle data and no credentials.
- `socat` is an optional runtime dependency, invoked as a separate process and
  not distributed with this project.
