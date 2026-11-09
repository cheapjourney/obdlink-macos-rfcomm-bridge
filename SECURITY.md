# Security

Die Sicherheitsanalyse dieses Projekts liegt in [`docs/SECURITY.md`](docs/SECURITY.md).
Kurzfassung:

- Der gesicherte Modus ist der empfohlene Weg; der Legacy-TCP-Pfad ist seit v0.2.0 Opt-in.
- Das Gate ist eine **fahrzeugspezifische** Allowlist, keine universelle Firewall.
- Die Bridge führt keine ISO-TP-Reassemblierung durch und interpretiert keine
  Diagnoseantworten.
- Schwachstellen bitte nicht öffentlich als Issue melden, sondern an den Maintainer.
