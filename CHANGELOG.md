# Changelog

All notable changes to this project are documented here.
This project follows [Semantic Versioning](https://semver.org/).

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
