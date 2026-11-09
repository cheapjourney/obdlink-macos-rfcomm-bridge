# Security model — v0.2.0

## Schichten

1. Transport: Bluetooth SPP/RFCOMM über IOBluetooth (oder optionaler Legacy-TCP-Pfad).
2. Steuerkanal: lokaler Unix-Socket mit NDJSON.
3. Gate: schmale Allowlist für Adapter- und Diagnosebefehle, zwei Modi.

Das Gate ist kein Diagnose-Stack und keine ECU-Firewall. Es reduziert die Menge der
Befehle, die den Adapter erreichen; es macht keinen Write sicher und prüft keinen
Fahrzeugzustand.

## Socket-Lebenszyklus

- Verzeichnis: wird mit 0700 angelegt, wenn es fehlt. Existiert es, wird es **nicht**
  geändert; nicht eigener Besitzer oder gruppen-/weltbeschreibbar ⇒ Abbruch (Exit 8).
- `flock` auf `<socket>.lock` serialisiert Starts; der Kernel gibt die Sperre beim
  Prozesstod frei. Zweite Instanz ⇒ Exit 7.
- Vorhandener Pfad: `lstat`; alles außer einem Socket (Datei, Verzeichnis, Symlink, FIFO)
  wird **nicht** entfernt ⇒ Exit 8.
- Socket ohne Listener (verwaist) wird nach Inode-Vergleich entfernt; ein erreichbarer
  Socket gilt als live und wird nie entfernt.
- Cleanup entfernt nur den Node, dessen Inode beim Bind aufgezeichnet wurde.
- Socket-Rechte 0600, `chmod`-Fehler ⇒ Exit 6.

## Bekannte Grenzen

- Ein lokaler Nutzer mit Zugriff auf das Socket-Verzeichnis kann jeden erlaubten Befehl
  senden. Das Gate ersetzt keine Client-Disziplin.
- Der Token-Vergleich ist ein normaler String-Vergleich, keine konstante Laufzeit.
- Die Allowlist ist fahrzeugspezifisch (Smart 453, EMM/Headunit) und nicht übertragbar.
- Integrität beruht auf Dateisystemrechten und SSH, nicht auf Signaturen.

## Bekannte niedrige Cleanup-Einschränkungen (v0.2.0)

Diese Punkte sind lokale Same-User-Risiken. Sie überschreiten keine
Privilegiengrenze und ermöglichen keinen Remote- oder CAN-Bypass. Sie werden in
dieser Dokumentationsphase **nicht** durch Codeänderungen behoben.

- **O-1 — Post-Bind-Fehlerpfad:** Nach erfolgreichem `bind` kann ein Fehler bei
  `chmod`, `listen` oder `recordBoundSocket` den gerade erzeugten Socket
  zurücklassen, weil `release()` vor dem Setzen von `ownsSocket` aufgerufen wird.
  Der nächste Start erkennt den Node als verwaist; der Fehlerpfad selbst räumt
  ihn nicht auf.
- **O-2 — zusätzliche UID-Prüfung im Cleanup:** `recordBoundSocket()` prüft den
  aktuellen Node nicht auf `S_IFSOCK` und Eigentümerschaft; `release()` prüft
  Inode/Device/Typ, aber nicht die UID. Ein Same-User-Prozess könnte den Node im
  kurzen Fenster nach dem Bind ersetzen.
- **O-3 — theoretische Same-User-Race-Condition:** Die Inode-/Device-Prüfung vor
  `unlink` und der `unlink` selbst sind nicht atomar. Ein Same-User-Prozess kann
  theoretisch dazwischen den Pfad ersetzen; es wird keine Privilegiengrenze
  überschritten.

Die drei Punkte sind in den Phase-10.7-/10.8-Berichten als niedrig eingestuft.
Sie sind keine allgemeine Sicherheitsgarantie und kein Ersatz für eine
Client-Disziplin.
