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
