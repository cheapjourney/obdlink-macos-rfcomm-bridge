# Allowlist — Profil Smart 453 (EMM + Headunit)

Die Liste ist ein **fahrzeugspezifisches Profil**, keine universelle Sicherheitsfunktion.
Prüfdatum: 2026-11-09. Fahrzeugfamilie: Smart 453, ein EMM (0x74D/0x76D) und eine
Headunit (0x747/0x767). Teilenummern und Fahrzeugidentität bleiben im privaten
Forschungsarchiv.

## adapter-only (und simulation)

`ATI STI STDI ATZ AT@1 ATE0 ATE1 ATL0 ATL1 ATS0 ATS1 ATH0 ATH1 ATD0 ATD1 ATCAF0 ATCAF1 ATRV`

Blockiert: alle `21`/`22`-Diagnoseanfragen, `300000`, sowie jede Protokoll-, Adress- oder
Timing-Konfiguration (`ATSH`, `ATCRA`, `STP`, `STCAF`, `STCFCPA`, `ATAT`, `STPTO`, `ATSP6`,
`ATCFC`, `ATFCSM`, `ATAL`, `ATDP`).

## vehicle-readonly

Adapterbefehle nach demselben Regex wie im Python-Gate (inkl. `STP 33`, `STCAF 0`,
`ATSH`/`ATCRA`, `STCFCPA a,b`, `ATAT0`, `STPTO 1..65535`) plus Diagnose-Reads:

`22F187 22F18E 21EF 2180 2106 2107 226C14 226C15 226C1C 226C20`, und `300000` als
einziger Flow-Control-Rahmen.

Alles andere wird abgewiesen, insbesondere `10`, `11`, `14`, `2E`, `3B`, `27`, `31`, `23`,
`34`–`37` und jeder DID außerhalb der Liste.

## Zwei Gates, zwei Entscheidungen

Python und Swift prüfen beide. Gemessen über 48 Kommandos: 46 gleiche Entscheidungen,
2 bewusst verschieden — `217F` und `2164` erlaubt Python, blockiert Swift. Der Swift-Gate
ist die engere Seite; beide müssen zustimmen.
