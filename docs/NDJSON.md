# NDJSON control protocol — v1

Der Vertrag, wie er in `SecuredBridge.swift` implementiert ist (Stand v0.2.0).
Kein Entwurf: jede Zeile hier ist gegen den Code geprüft.

## Transport

Unix-Domain-Stream-Socket, ein JSON-Objekt pro Zeile, `\n`-getrennt, UTF-8.
Lesepuffer 8192 Byte. Genau ein Client gleichzeitig.

## Client → Server

| Typ | Pflicht | Optional |
|---|---|---|
| `hello` | `type`, `protocol` (1), `mode` | `vehicle_token` (Pflicht bei `vehicle-readonly`) |
| `write` | `type`, `data` | — |
| `read` | `type` | `timeout` (Sekunden, Default 2.0) |
| `close` | `type` | — |

## Server → Client

`hello_ack{protocol,adapter,stn,mode,simulated}`, `ok`, `blocked{reason}`,
`line{data}`, `timeout{partial}`, `closed`, `error{reason}`.

## Fehlerwerte

`invalid json`, `message too long`, `hello expected`, `protocol mismatch`,
`mode mismatch`, `token missing`, `adapter identification failed`, `write failed`,
`unknown message`.

Fehler beenden die Verbindung, außer `unknown message` (Verbindung bleibt offen).

## Bewusst nicht vorhanden

- **Keine Korrelations-ID.** Antworten sind strikt sequenziell; ein Client darf nicht
  pipelinen.
- **Keine Zeitstempel** im Protokoll.
- **Kein numerischer Fehlercode** — `reason` ist Freitext.

Ein v2 mit IDs und Codes ist denkbar, aber nicht Teil von v0.2.0.
