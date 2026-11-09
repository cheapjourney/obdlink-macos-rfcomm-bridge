# Tests

Alles hier läuft ohne Bluetooth, Adapter oder Fahrzeug.

## Swift-Selbsttest

```bash
make build && ./build/obdlink-rfcomm --self-test
```

22 Prüfungen: TCP-Pfad, Zeilenpuffer (echter MX+-Burst, geteilte Mehrfachantwort,
43 Frames über drei Chunks) und seit v0.2.0 der Socket-Lebenszyklus (Verzeichnis 0700,
Lock gegen zweite Instanz, reguläre Datei/Symlink verweigert, verwaister Socket entfernt,
lebender Socket geschützt, 0600, eigener Node entfernt, fremder Node nicht).

## Python-Suiten (separates Projekt)

Gegen den gebauten Binary, ohne Hardware:

```bash
cd ~/smart453-phase5_1
python3 -m unittest tests.test_phase5_1_integration tests.test_phase6_emm_read tests.test_phase6_4_full_config
```

Die Suiten zeigen auf `~/obdlink-macos-rfcomm-bridge/build/obdlink-rfcomm`. Für einen
Test gegen einen anderen Build die Konstante `BRIDGE` im Testmodul umbiegen.

## Golden Messages

`tests/test_golden_protocol.py` spricht das NDJSON-Protokoll gegen die echte Binary im
Simulations- und `--simulate-transport`-Modus. 28 Prüfungen, inklusive Fehlerfällen.

## Lifecycle-Regression

`tests/regression_secured_mode.py`: 14 Prüfungen gegen den echten Prozess — zweite
Instanz (Exit 7), SIGTERM, reguläre Datei und Symlink (Exit 8), verwaister Socket,
Rechte, NDJSON-Fehler, sequenzielle Verarbeitung, `--tcp`-Opt-in.

## CI

`.github/workflows/ci.yml` baut auf `macos-latest` und führt den Selbsttest aus. Die
Python-Suiten liegen in einem separaten Projekt und laufen dort.
