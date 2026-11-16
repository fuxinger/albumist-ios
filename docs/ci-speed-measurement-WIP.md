# UI-Pipeline-Tempo: Messung (WIP, pausiert 16.11. ~22:35 UTC)

Quelle: `gh api repos/fuxinger/sortly-ios/actions/runs/<id>/jobs` und Job-Logs. Zeiten in Minuten.
noQueue = Wanduhr minus Wartezeit (Build + letzte Gruppe) in der Runner-Warteschlange.

## Läufe (Basis)

| Lauf | Branch | Gruppen | Wand | Core (Linux) | Build-Queue | Build | letzte Gruppe | Gruppen-Queue | Vorlauf | Test-Schritt | Nachlauf | noQueue | Queue | Mac-Min |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 43893790053 | pro-ci2 | 3 | 64.7 | 2.4 | 0.0 | 1.7 | accessibility | 0.1 | 4.2 | 55.6 | 0.6 | 64.7 | 0.1 | 139.3 |
| 43906501407 | pro-ci2 | 3 | 60.6 | 2.6 | 0.0 | 1.3 | accessibility | 0.0 | 7.4 | 48.5 | 0.7 | 60.5 | 0.1 | 134.3 |
| 43918684247 | pro-ci2 | 4 | 52.6 | 2.6 | 0.1 | 1.9 | accessibility | 0.1 | 9.6 | 37.4 | 0.5 | 52.5 | 0.1 | 128.2 |
| 43930277920 | ui-fix | 4 | 84.0 | 3.6 | 0.1 | 1.5 | other flows | 44.6 | 3.3 | 30.1 | 0.6 | 39.4 | 44.7 | 123.9 |
| 43945035122 | ui-fix | 4 | 53.2 | 2.7 | 0.0 | 2.2 | other flows | 0.1 | 6.0 | 41.0 | 0.9 | 53.1 | 0.1 | 145.6 |
| 43930271358 | pro-switches | 5 | 84.9 | 3.0 | 0.1 | 2.0 | device conditions | 0.1 | 5.6 | 73.1 | 0.8 | 84.8 | 0.1 | 245.0 |
| 43949880264 | pro-switches | 5 | 87.4 | 2.7 | 0.0 | 2.6 | device conditions | 0.0 | 3.9 | 77.5 | 0.4 | 87.4 | 0.1 | 238.0 |

Laufende Läufe zur Messzeit: 43954645840 (ui-fix: Build 12.8 Min. Queue, accessibility 33.1 Min. Queue),
43964816778 (pro-switches: contrast 16.7 Min. Queue), 43966229908 (ui-fix, pending).

## Wohin die Minuten gehen (4-Gruppen-Pipeline, Lauf 43945035122, 145.6 Mac-Min.)

- Tests selbst: ~119.5 Mac-Min. (82 %). Kritischer Pfad = Gruppe „other flows“ (41.0 Min. Test-Schritt).
- Vorlauf je Gruppe (Simulator-Boot + Download): 3.3–9.6 Min., ~20 Mac-Min. pro Lauf (14 %).
  Boot 3–7 Min. Download (17 MB) sonst 1–3 s, neben dem bootenden Simulator bis 9.0 Min.
  (43918684247 accessibility), Entpacken bis 2.6 Min. (43906501407) → CPU/IO-Konkurrenz.
- Nachlauf ~0.5–1 Min. je Gruppe; xcodebuild-Overhead im Test-Schritt ~1.5–3 Min. je Gruppe.
- UI build: 1.3–2.6 Min. (brew install xcodegen ~10 s, Upload 17 MB ~1 s) → kein Hebel.
- Core (Linux) 2.4–3.6 Min. seriell vor dem Build (Eigentümer-Entscheidung „erst schnell, dann teuer“).
- Queue: ohne parallele Läufe ~0; mit 2+ parallelen UI-Läufen bis 44.6 Min. auf dem kritischen Pfad
  (5-Mac-Limit). Kein Retry (FLAKY) in den ausgewerteten Läufen.

## Test-Schritt je Gruppe (Median, 4-Gruppen-Läufe)

full flow ~29 (test1 21.9–26.9) · other flows ~38 (Tests 2–7 + Suche; Suche 2.7–3.4) ·
accessibility 1–4 ~32 · contrast ~15. Erster Test einer Gruppe trägt Onboarding + Beispiel-Mediathek
(test2 als erster 5.9–7.9 Min., nicht als erster 1.4 Min. in pro-switches).

pro-switches (5 Gruppen): device conditions 73–77.5 (test11 LargeLibrary allein 28.5–30.3),
other 65–67, accessibility ~29, full ~27 (bestanden), contrast 13–20.

## Umgesetzt auf claude/ci-speed (Commit b2e545a)

1. Build-Produkte werden vor dem Simulator-Boot geladen und entpackt (statt parallel).
2. SortlySearchUITests in die Gruppe „full flow“ (nach test1, wie die Klasse geschrieben ist):
   erwartet Pro-Gruppen ~32/~35 statt ~29/~38. Gleiche Tests, Geräte, Einstellungen.
3. `ui_tests.py boot` druckt `UI_BOOT_TIME boot N s, prepare M s`.

Messlauf 43969931127 (claude/ci-speed) gestartet 22:25:34 UTC, bei Pause noch in Core (Linux),
parallel 2 weitere UI-Läufe aktiv + 1 pending → Queue erwartet; Ergebnis noch nicht ausgewertet.

## TSan (Commit 3bfa1f0)

`.github/workflows/sanitize.yml` (workflow_dispatch + workflow_call, Input `sanitize: thread`) und
`.github/scripts/sanitizer_report.py` (+ Tests). Noch nicht gelaufen: Dispatch geht erst, wenn die
Datei auf dem Default-Branch liegt (HTTP 404). Lokal vorbereitet, NICHT gepusht: Wegwerf-Branch
`claude/ci-speed-tsan` (Worktree /home/user/wt-tsan, Commit c0cad80) mit Push-Trigger.

## Offen

- Messlauf 43969931127 auswerten (Wand, Mac-Min., Queue-Anteil, UI_BOOT_TIME).
- TSan einmal laufen lassen und Befunde berichten.
- Zeile in docs/IMPROVEMENTS.md mit Vorher/Nachher.
- Empfehlung pro-switches (5 Gruppen): Pro-Tests (~162 Test-Min.) auf drei Pro-Jobs à ~55 verteilen
  (test1 + 1b/1c/1d/4/5/7/Suche · DC 01–04,10,11 · DC 05–09 + test2,3,6); Klassen, die vor
  SortlyFlowUITests sortieren, nie in die test1-Gruppe (test1 braucht frischen Simulator).
- Nicht geändert: core-linux ∥ build (würde ~2.5 Min. sparen, bricht aber die Eigentümer-Regel
  „kein Mac-Job bei roten Kern-Tests“); xcodegen-Binary (spart ~10 s); Artefakt (17 MB, 1 s).
