# Release blockers — v0.2.0 (branch fix/v0.2.0-release-hardening)

Stand 2026-11-09, Basis `465411b`. Was hier noch steht, ist nach diesem Branch offen.

## Erledigt auf diesem Branch

| Blocker | Lösung |
|---|---|
| Socket-Ownership | `SocketLifecycle`: flock, lstat-Typprüfung, Live-Probe, Inode-Vergleich vor `unlink`, Cleanup nur für den eigenen Node |
| Verzeichnis wurde blind auf 0700 gesetzt | Verzeichnis wird nur angelegt, nie nachträglich geändert; gruppen-/weltbeschreibbar ⇒ Abbruch |
| `chmod`-Rückgabewert ignoriert | geprüft, Fehler ⇒ Exit 6 nach Cleanup |
| Zweite Instanz | Exit 7, die erste bleibt erreichbar |
| NDJSON: stiller Abbau nach dem Handshake | `error: invalid json` als strukturierte Antwort, dann Verbindung zu |
| Überlange Nachricht | deterministisch `error: message too long`, Zeilenrest wird verworfen |
| Legacy-TCP ohne Gate | nur noch mit `--tcp`, sonst Exit 2; zweiter Client wird abgewiesen |
| Selbsttest ohne Socket-Modus | 10 zusätzliche Prüfungen (Lock, Typprüfung, stale/live, Rechte, Ownership) |

## Offen (nicht blockierend für Review, blockierend für Tag)

1. **Keine Korrelations-ID** in NDJSON v1 — bewusst nicht geändert; Vertrag bleibt
   „ein Request zur Zeit". Ein v2-Vorschlag ist dokumentiert, nicht implementiert.
2. **`blocked` ohne Fehlercode** — Freitext bleibt v1-kompatibel.
3. **Allowlist ist fahrzeugspezifisch** — muss im README als Profil mit Prüfdatum stehen,
   nicht als universelle Funktion.
4. **Byte-identische Builds** — mit Swift 5.7.2 auf macOS 12.7.6 nicht nachgewiesen
   (Toolchain-/SDK-Metadaten). Reproduzierbar ist der Ablauf, nicht das Byte-Ergebnis.
5. **Kein Fahrzeugtest dieser Version.** Die neue Lifecycle-Logik ist rein lokal geprüft;
   die letzte Fahrzeugmessung lief auf `465411b`.

## Abgleich mit Phase 9.0 (Audit vom 2026-11-09)

Phase 9.0 hat vier Bridge-Blocker festgehalten. Stand auf diesem Branch:

| ID | Blocker (9.0) | Status jetzt |
|---|---|---|
| B-1 | Socket-Ownership: bedingungsloses `unlink`, kein Lock/Inode-Check, Parent-chmod, ungeprüftes Socket-chmod | **GESCHLOSSEN** — `SocketLifecycle` mit flock, lstat-Typprüfung, Live-Probe, Inode-Vergleich, `O_NOFOLLOW` für die Lock-Datei, geprüftes chmod; 10 neue Selbsttest-Prüfungen + 15 Lifecycle-Regressionen |
| B-2 | Selbsttest deckt den gesicherten Modus nicht ab | **GESCHLOSSEN für den Lifecycle** — 23 Selbsttest-Prüfungen. NDJSON/Gate bleiben in den Python-Golden-Tests (29), nicht im Swift-Selbsttest |
| B-3 | Kein macOS-CI, kein reproduzierbares Release-Artefakt | **TEILWEISE** — `.github/workflows/ci.yml` vorhanden, auf GitHub noch nicht gelaufen; byte-identische Builds nicht nachgewiesen |
| B-4 | 85-Test-Harness und 28 Golden Tests nicht im öffentlichen Repo | **TEILWEISE** — `tests/test_golden_protocol.py` (29 Prüfungen) und `tests/regression_secured_mode.py` (15) liegen jetzt im Repo; die Python-Parser-Suiten bleiben im separaten Projekt |

Weiterhin gilt aus 9.0: die Bridge reassembliert **kein** ISO-TP (macht der Python-Client).
