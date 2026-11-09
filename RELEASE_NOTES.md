# v0.2.0 release notes

## Publication state

This document describes the v0.2.0 change set. Whether a tag or GitHub release
exists is recorded by the repository's tag and release metadata; this file does
not assert a publication state.

Prepared: 2026-11-09.

## Neu

- Gesicherter Unix-Socket-Modus mit NDJSON v1 und serverseitigem Befehl-Gate
  (adapter-only, vehicle-readonly, simulation).
- Deterministische Fehlerantworten: `invalid json` und `message too long`
  beenden eine fehlerhafte Verbindung mit einer Nachricht statt mit Stille.
- Socket-Lebenszyklus: `flock` gegen Doppelstart (Exit 7), `O_NOFOLLOW` für die
  Lock-Datei, Typprüfung des Pfads (Exit 8), Inode-geprüftes Cleanup,
  Verzeichnis wird nie nachträglich chmod'ed.
- Selbsttest um Lifecycle-Prüfungen erweitert; aktuelle Baseline **23/23**.

## Geändert

- **Legacy-TCP/PTY ist Opt-in.** Ohne `--tcp` startet der Roh-Relay nicht mehr
  (Exit 2). Wer v0.1.0-Kommandos weiter nutzt, muss `--tcp` ergänzen. Der
  Rohpfad hat kein Gate.
- Der Legacy-Relay nimmt nur noch einen Client gleichzeitig an; ein zweiter wird
  abgewiesen statt den ersten zu verdrängen.
- Die v0.1.0-Helferskripte `scripts/start.sh` und `scripts/verify.sh` bleiben
  Legacy-TCP-Helfer; `start.sh` übergibt jetzt ausdrücklich `--tcp`. Der
  gesicherte Unix-Socket-Modus bleibt der empfohlene Betriebsweg.

## Sicherheit

- Zweite Instanz kann den Socket einer laufenden Instanz nicht mehr entfernen.
- Reguläre Dateien und Symlinks am Socketpfad werden nicht gelöscht und nicht
  verfolgt.
- Überlange Nachrichten werden verworfen, ohne Speicher wachsen zu lassen.
- Das Gate ist eine fahrzeugspezifische Allowlist, keine universelle Firewall.
- Drei niedrige lokale Cleanup-Einschränkungen (O-1 bis O-3) sind in
  `docs/SECURITY.md` dokumentiert; sie überschreiten keine lokale
  Benutzergrenze und sind nicht behoben.

## Fahrzeugvalidierung (begrenzter Read-only-Funktionstest)

Getesteter Stand:

- Bridge-Commit: `da9dc6518c01770679ce97cc962d9d2f0eb4d49e`
- Binary SHA-256: `f751706a4938d11eaf0911340e35b2cc140e2dbe8982a64f1abc8488006641df`
- Adapter: OBDLink MX+ r3.1.3 / STN2255 v5.10.3
- Build: Swift 5.7.2, macOS 12.7.6, x86_64

Bestätigte Reads:

- EMM `21 80`: 26 Byte, byte-identisch zur Phase-6.1-Baseline.
- EMM `21 07`: `61 07 00` (3 Byte), byte-identisch zur Phase-6.3-Baseline.
- Headunit `21 80`: 26 Byte, byte-identisch zur historischen Messung.
- Headunit `22 F1 87`: 13 Byte, byte-identisch zur historischen Messung.
- Headunit `22 6C 1C`: `62 6C 1C 78`, unverändert gegenüber dem historischen
  Read-back.

Es wurden keine Session-Anforderung, kein Write, keine Konfigurationsänderung,
kein Reset und kein SecurityAccess ausgeführt. Die Fahrzeugkonfiguration wurde
nicht verändert.

Der Test ist **kein allgemeiner Kompatibilitäts- oder Funktionstest**. Er deckt
nur diese Reads, diesen Adapter und diesen Commit ab. Weitere Dienste, Sessions,
Writes, Multimedia-CAN, andere Adapter, andere Firmware und andere Fahrzeuge
wurden nicht getestet.

Ein erster Harness-Lauf hatte einen clientseitigen
Antwort-Synchronisationsfehler: `21 07` wurde mit dem Default-Header an `0x7E0`
gesendet und negativ mit `7E8 03 7F 21 12` beantwortet. Diese rein lesende
Anfrage änderte nichts. Nach der Harness-Korrektur wurden die Messungen mit dem
beabsichtigten Header wiederholt; die oben genannten Antworten stammen aus den
korrigierten Läufen.

## Tests

Die folgenden fünf Suiten wurden auf dem MacBook gegen die Kandidaten-Binary
ausgeführt und sind externe Ergebnisse, keine lokalen Tests auf dem iMac:

| Suite | Ergebnis |
|---|---|
| Swift-Selbsttest | **23/23** |
| Lifecycle-Regression | **15/15** |
| Golden Messages | **29/29** |
| Python-Bridge-Integration | **22/22** |
| Python-Parser/Decoder | **63/63** |

Die GitHub-CI ist enger: Sie baut Debug und Release auf `macos-latest`, führt
den Swift-Selbsttest in beiden Builds aus und prüft den `--tcp`-Negativtest.
Sie führt nicht alle fünf Suiten aus. Ein grüner CI-Status ist kein Nachweis
für die Lifecycle-, Golden-, Python-Bridge- oder Parser-Suiten.

## Bekannte Einschränkungen

- Keine Korrelations-IDs, keine Zeitstempel, keine numerischen Fehlercodes im
  NDJSON-v1-Protokoll; ein Request zur Zeit.
- Keine ISO-TP-Reassemblierung in der Bridge — die macht der Python-Client.
- Die Allowlist ist fahrzeugspezifisch (Smart 453 EMM/Headunit), keine
  universelle Sicherheitsfunktion.
- Byte-identische Builds sind mit Swift 5.7.2 auf macOS 12.7.6 nicht
  nachgewiesen.
- Die v0.1.0-Helferskripte bleiben auf den ungegateten Legacy-TCP-Pfad
  beschränkt; `start.sh` übergibt `--tcp` ausdrücklich, startet aber keinen
  gesicherten Socket.
- O-1 bis O-3: niedrige lokale Cleanup-Einschränkungen, siehe
  `docs/SECURITY.md`.

## Nicht enthalten

- Keine allgemeine Fahrzeug- oder Diagnosekompatibilität.
- Die Bridge ist eine **Transportkomponente**, keine Diagnose-Engine. Die
  ISO-TP-Reassemblierung erfolgt im Python-Diagnoseclient, nicht in der Bridge.
- Keine Android-Auto-/CarPlay-Aktivierung und keine Projektionsaussage.
- Keine proprietäre Firmware, DDT-Datenbank oder privaten Rohdaten.
