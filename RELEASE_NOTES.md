# v0.2.0 release notes (candidate, not tagged)

## Neu

- Gesicherter Unix-Socket-Modus mit NDJSON v1 und Befehl-Gate (adapter-only,
  vehicle-readonly).
- Deterministische Fehlerantworten: `invalid json` und `message too long` beenden eine
  fehlerhafte Verbindung mit einer Nachricht statt mit Stille.
- Socket-Lebenszyklus: `flock` gegen Doppelstart (Exit 7), Typprüfung des Pfads (Exit 8),
  Inode-geprüftes Cleanup, Verzeichnis wird nie nachträglich chmod'ed.
- Selbsttest um 10 Prüfungen des gesicherten Modus erweitert (22 gesamt).

## Geändert

- **Legacy-TCP/PTY ist Opt-in.** Ohne `--tcp` startet der Roh-Relay nicht mehr (Exit 2).
  Wer v0.1.0-Kommandos weiter nutzt, muss `--tcp` ergänzen. Das ist eine bewusste
  Bruchstelle: der Rohpfad hat kein Gate.
- Der Legacy-Relay nimmt nur noch einen Client gleichzeitig an; ein zweiter wird
  abgewiesen statt den ersten zu verdrängen.

## Sicherheit

- Zweite Instanz kann den Socket einer laufenden nicht mehr entfernen.
- Reguläre Dateien und Symlinks am Socketpfad werden nicht gelöscht und nicht verfolgt.
- Überlange Nachrichten werden verworfen, ohne Speicher wachsen zu lassen.

## Nicht enthalten

- Keine Korrelations-IDs, keine Zeitstempel, keine Fehlercodes im Protokoll.
- Keine ISO-TP-Reassemblierung in der Bridge — die macht der Python-Client.
- Kein Fahrzeugtest dieser Version; die letzte reale Messung lief auf `465411b`.
