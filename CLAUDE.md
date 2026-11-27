# Albumist: Regeln für jeden Agenten

Diese Datei liest jeder Agent zuerst, auch jeder Unter-Agent. Ein Auftrag an einen Unter-Agenten
beginnt mit „Lies CLAUDE.md“. Sie fasst nur zusammen; die Einzelheiten stehen in den genannten
Dateien. Gilt etwas noch nicht technisch, steht davor „Ziel:“.

## Schutz der Fotos (gilt immer, Wort für Wort aus den Projektvorgaben)

- Fotos und Auswertungen verlassen nie das iPhone.
- Albumist löscht oder verändert nie Originalfotos. Es legt nur Alben und Ordner an und entfernt nur diese.
- Ist unklar, ob ein Schritt geklappt hat, gilt er als nicht erledigt.
- Keine stillen Änderungen an der Mediathek: Jede Änderung sieht der Nutzer vorher und kann sie rückgängig machen.

## Nie

- Gegen den Schutz der Fotos verstoßen.
- Ohne Auftrag in `main` zusammenführen. Reine Doku-Änderungen dürfen die Stränge selbst mergen.
- Einen Lauf wiederholen, bis er grün ist. Ein wackelnder Test wird gezählt (`UI_FLAKY_RETRY`) und repariert.
  Ausnahme Kontrastprüfung (Koordinator 27.11.2026): Hängt die Barrierefreiheitsprüfung zweimal, und die
  drei anderen Prüfarten werden fertig, gibt es genau eine Wiederholung nur der Kontrastprüfung, nachdem die
  App im Hintergrund war und zurückkam (derselbe Bildschirm), gezählt als `UI_FLAKY_RETRY` und in der
  Tageskennzahl ausgewiesen (`AccessibilityUITests.contrastHangRetry`). Hängt sie wieder: echter Befund.
  Eine Kontrastprüfung, die fertig wird und etwas findet, wird nie wiederholt.
- Fremde Mac-Läufe abbrechen. Läufe auf einem überholten Stand bricht die Bau-Strecke selbst ab.
- Als Unter-Agent `mcp__hearthbot__*` aufrufen; mit Fuchs spricht nur der Strang.
- Neue Funktionen in Version 1.0 aufnehmen: Der Umfang ist eingefroren (Entscheidung 12,
  `docs/DECISIONS.md`); neue Ideen kommen auf die Liste „Später / 1.1“.

## Immer

1. Zuerst `docs/CODEMAP.md` lesen, dann gezielt die betroffenen Dateien.
2. Ursache mit Beleg (Log, Diagnosebericht, nachgestellter Test), nie raten. Prüfen, wo derselbe Fehler noch steckt.
3. Jeder Fehler und jeder neue Fall bekommt einen Test auf der schnellsten Ebene, die ihn sicher fängt:
   Linux-Kerntest vor App-Test auf dem Mac, Bedienungstest nur für das, was nur die Oberfläche zeigt.
   Fand Fuchs oder ein Tester den Fehler, wird auch die Testlücke benannt und geschlossen.
4. Swift-Code vor jedem Push im Container bauen und seine Tests dort ausführen
   (Werkzeug und Befehl: `STATUS.md`, Abschnitt „Rahmenbedingungen“). Zeilen höchstens 160 Zeichen.
5. Pull Requests als Entwurf öffnen (nur Rauchtest). Mit dem letzten Commit auf „Ready for review“:
   das startet den vollen Bedienungsdurchgang, „UI verdict (full)“ ist das Merge-Tor
   (`.github/pull_request_template.md`, `docs/TESTFLIGHT.md`). Nicht auf das Go eines anderen Strangs warten.
6. Erst messen, dann optimieren, auch bei Tests und Bau-Strecke: Laufzeit vorher und nachher in den PR.
7. Der Diagnosebericht wächst mit neuen Funktionen mit.
8. Am Ende berichten: geändert, getestet (mit Lauf), offen, selbst entschieden (umkehrbar).

## Prüfen nach Risiko

| Stufe | Bereiche | Was nötig ist |
|---|---|---|
| A | Analyse, Zählung, Alben anlegen oder rückgängig machen, Käufe, Hintergrundarbeit, Bau-Strecke, Upload-Tor | alle Fälle der Prüfliste in den Projektvorgaben als Tests, dazu eine Zweitprüfung |
| B | Bildschirme | Entwurf für Fuchs vor dem Bau, Bildschirmfotos hell, dunkel, größte Schrift, betroffene Fälle der Prüfliste |
| C | Texte, Tests, Doku | schnelle Tests, ein echter Lauf |

Zweitprüfung: Fable nur für Analyse, Zählung, Alben anlegen/rückgängig und Käufe; sonst ein frischer
Opus-Agent ohne die Schlussfolgerung des Autors. Sie beginnt erst, wenn der Code gebaut ist und die
schnellen Tests grün sind. Höchstens zwei Runden; Runde 2 prüft nur die Korrekturen aus Runde 1.
Kleinigkeiten danach kommen auf die Befunde-Liste. Findet Runde 2 noch einen schweren Fehler, wird der
Ansatz vereinfacht und Fuchs erfährt es. Der PR nennt Prüfer, Commit und die Zahl der Runden.

## Wo was steht

| Frage | Datei |
|---|---|
| Entscheidungen von Fuchs | `docs/DECISIONS.md` |
| Testplan und Tore | `docs/TEST_PLAN.md`, `docs/TEST_COVERAGE_MAP.txt` |
| Bau-Strecke, TestFlight | `docs/TESTFLIGHT.md`, `.github/workflows/`, `.github/scripts/` |
| Feste Kennungen für Bedienungstests | `docs/UI_IDENTIFIERS.md` |
| Bekannte Grenzen | `docs/KNOWN_LIMITATIONS.md` |
| Start-Checkliste | `docs/launch/LAUNCH_CHECKLIST.md` |
| Datenschutz-Versprechen (wortgleich geprüft von `PromiseWordingTests`) | `docs/PRIVACY.md` |

Das Repository ist öffentlich: keine privaten Fotos, Namen oder Orte in Screenshots, Logs und Tests.
