# Tests

Die hier beschriebenen Offline-Suiten laufen ohne Bluetooth, ohne Adapter und
ohne Fahrzeugkommunikation. Die Zahlen sind die verifizierte v0.2.0-Baseline;
sie wurden auf dem MacBook gegen die Kandidaten-Binary ausgeführt und sind keine
lokalen Testergebnisse des iMac.

## Swift-Selbsttest

```bash
make build && ./build/obdlink-rfcomm --self-test
```

**23/23 Prüfungen**: TCP-Pfad, Zeilenpuffer (echter MX+-Burst, geteilte
Mehrfachantwort, 43 Frames über drei Chunks) und seit v0.2.0 der
Socket-Lebenszyklus (Verzeichnis 0700, Lock gegen zweite Instanz, reguläre
Datei/Symlink verweigert, verwaister Socket entfernt, lebender Socket geschützt,
0600, eigener Node entfernt, fremder Node nicht).

Historisch: v0.1.0 hatte 9 Selbsttest-Prüfungen, ausschließlich für den
TCP-Pfad. Diese Zahl ist nicht die v0.2.0-Baseline.

## Lifecycle-Regression

`tests/regression_secured_mode.py`: **15/15 Prüfungen** gegen den echten Prozess
— zweite Instanz (Exit 7), SIGTERM, reguläre Datei und Symlink (Exit 8),
verwaister Socket, Rechte, NDJSON-Fehler, sequenzielle Verarbeitung,
`--tcp`-Opt-in.

## Golden Messages

`tests/test_golden_protocol.py` spricht das NDJSON-Protokoll gegen die echte
Binary im Simulations- und `--simulate-transport`-Modus: **29/29 Prüfungen**,
inklusive Fehlerfällen.

## Python-Bridge-Integration

Gegen die gebaute Binary, ohne Hardware: **22/22 Prüfungen** im separaten
Python-Projekt. Die Suiten zeigen auf
`~/obdlink-macos-rfcomm-bridge/build/obdlink-rfcomm`; für einen anderen Build
muss die Konstante `BRIDGE` im Testmodul umgebogen werden.

## Python-Parser/Decoder

**63/63 Prüfungen** im separaten Python-Projekt. Diese Suite prüft Parser und
Decoder, nicht die Swift-Bridge.

## GitHub CI

`.github/workflows/ci.yml` läuft auf `macos-latest` und prüft:

- Debug-Build;
- Release-Build;
- Swift-Selbsttest in beiden Builds;
- Negativtest: Legacy-TCP ohne `--tcp` endet mit Exit 2.

Die GitHub-CI führt **nicht** die Lifecycle-, Golden-, Python-Bridge- oder
Parser/Decoder-Suiten aus. Ein grüner CI-Status ist daher nur ein Nachweis für
Build, Selbsttest und den TCP-Opt-in-Negativtest.

## Helferskripte

Die Shell-Helfer werden lokal syntaktisch geprüft:

```bash
bash -n scripts/start.sh scripts/stop.sh scripts/verify.sh
```

`scripts/start.sh` ist ein Legacy-TCP/PTY-Helfer und übergibt seit v0.2.0
ausdrücklich `--tcp`. `scripts/verify.sh` verwendet diesen Helfer. Beide starten
keinen gesicherten Unix-Socket; der gesicherte Modus bleibt der empfohlene
Betriebsweg. Ein echter Starttest benötigt macOS und einen Adapter und wurde auf
dem iMac nicht ausgeführt.

## Fahrzeugtest

Der separate begrenzte Read-only-Fahrzeugtest ist kein Bestandteil dieser
Offline-Suiten. Er ist in `RELEASE_NOTES.md` dokumentiert: nur die dort
genannten Reads, ein Adapter und ein Commit; keine allgemeine
Fahrzeugkompatibilität.
