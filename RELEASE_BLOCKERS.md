# Pre-release limitations — v0.2.0

Status record: 2026-11-09. Basis: `main` at `882e51f`, branch
`fix/v0.2.0-release-hardening`, code head `da9dc65`. This is a
documentation/limitations record, not a tag or release record. The repository's
tag and release metadata is authoritative for publication state.

## Resolved on this branch

| Blocker | Resolution |
|---|---|
| Socket ownership | `SocketLifecycle`: flock, lstat type check, live probe, inode comparison before `unlink`, cleanup only for the recorded own node |
| Directory was blindly set to 0700 | Directory is only created, never changed afterwards; group/world-writable ⇒ abort |
| `chmod` return value ignored | checked; failure ⇒ Exit 6 after cleanup |
| Second instance | Exit 7; the first instance remains reachable |
| NDJSON silent close after handshake | `error: invalid json` as structured response, then close |
| Overlong message | deterministic `error: message too long`; rest of line discarded |
| Legacy TCP without gate | only with `--tcp`, otherwise Exit 2; second client rejected |
| Self-test without socket mode | lifecycle checks added; current baseline 23/23 |

## Known limitations (not release-blocking)

1. **No correlation ID** in NDJSON v1 — deliberately unchanged; the contract is
   one request at a time. A v2 proposal is documented, not implemented.
2. **`blocked` without an error code** — free-text remains v1-compatible.
3. **Allowlist is vehicle-specific** — it is a Smart 453 EMM/headunit profile,
   not a universal security function. See `docs/ALLOWLIST.md`.
4. **Byte-identical builds** — not proven with Swift 5.7.2 on macOS 12.7.6;
   the process is reproducible, not the byte result.
5. **Legacy helper scripts** — `scripts/start.sh` and `scripts/verify.sh` are
   retained for the raw legacy path. `start.sh` now passes `--tcp` explicitly;
   neither helper starts the secured Unix-socket mode.
6. **Low-severity cleanup observations O-1 to O-3** — documented in
   `docs/SECURITY.md`; they are local, same-user limitations, not a remote or
   vehicle-safety bypass. They were not code-changed in this documentation
   phase.

## Vehicle validation

The hardened code head `da9dc65` received a **limited read-only function test** on
2026-11-09 with an OBDLink MX+ r3.1.3 / STN2255 v5.10.3:

- EMM `21 80`: 26-byte response, byte-identical to the baseline.
- EMM `21 07`: `61 07 00` (3 bytes), byte-identical to the baseline.
- Headunit `21 80`: 26-byte response, byte-identical to the historical baseline.
- Headunit `22 F1 87`: 13-byte identity response, byte-identical.
- Headunit `22 6C 1C`: `62 6C 1C 78`, unchanged from the historical read-back.

No session, write, configuration change, reset or security access was performed.
The initial harness sent `21 07` with the default header to `0x7E0`; the
negative answer `7E8 03 7F 21 12` was read-only and changed nothing. The harness
was corrected before the successful measurements.

This is not a general vehicle/diagnostic compatibility claim. Other services,
sessions, writes, multimedia CAN, adapters, firmware and vehicles are untested.

## CI status

GitHub Actions on PR #1 runs on `macos-latest`:

- Debug build;
- Release build;
- Swift self-test in both builds;
- negative test: legacy TCP without `--tcp` must exit 2.

For the code head `da9dc65`, both macOS check runs were successful. The workflow
does **not** run the 15 lifecycle, 29 golden, 22 Python bridge or 63 parser
tests; those are external MacBook results. A green CI badge is not evidence that
all five suites ran on GitHub.

## Phase 9.0 reconciliation

| ID | Phase 9.0 blocker | Current status |
|---|---|---|
| B-1 | Socket ownership: unconditional `unlink`, no lock/inode check, parent chmod, unchecked socket chmod | **CLOSED** — `SocketLifecycle` with flock, lstat type check, live probe, inode comparison, `O_NOFOLLOW` lock file, checked chmod; lifecycle tests added |
| B-2 | Self-test does not cover secured mode | **CLOSED for lifecycle** — 23 self-test checks; NDJSON/gate remain in Python golden tests (29) |
| B-3 | No macOS CI / reproducible release artifact | **PARTIAL** — CI exists and ran green for the code head; byte-identical builds remain unproven |
| B-4 | Test harness and golden tests not public | **PARTIAL** — `tests/test_golden_protocol.py` (29) and `tests/regression_secured_mode.py` (15) are public; the Python parser suites remain external |

The bridge still does **not** reassemble ISO-TP; that remains in the Python
client.
