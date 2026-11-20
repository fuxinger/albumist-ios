# Befunde: Stand der Arbeit

Stand: **20.11.2026, 20:50 Uhr**, `main` fdf9c30 (PR #12 zusammengeführt nach vollem Mac-Durchgang und 10k-Härtetest, alle grün; Bildschirmfotos aller Phasen angesehen). Build 40 ist hochgeladen (20.11. 21:46 Uhr); die Punkte aus PR #12 sind ✅.
Davor Build 38 = PR #10 (5f9ad8a).

Diese Liste enthält **jeden** Befund aus zwei Prüfungen, damit keiner vergessen wird:

- **Große Analyse vom 18.11.** (Fable-Analyse, 6 Prüfer): 81 Befunde, P1-01 bis P6-11.
- **Prüfung von außen vom 18.11.** (ChatGPT-Rückgabe): 42 Nummern, davon 3 doppelt, also 39 Befunde,
  G1-01 bis G7-02. Dazu 3 Funde, die beim Nachprüfen dazukamen (Z1 bis Z3).

## Zahlen

Nachgezählt 20.11. 21:50 Uhr nach Build 40. Davor 03:45 Uhr: Die Spalte „Prüfung von außen“ zählte Z3 (braucht dein OK) seit dem 19.11. als erledigt; richtig sind 30 erledigt und 2 für dich, zusammen 71 statt 72.

| Status | Große Analyse | Prüfung von außen | Zusammen |
|---|---:|---:|---:|
| ✅ erledigt | 59 | 35 | 94 |
| 🔧 in Arbeit | 4 | 0 | 4 |
| 📋 geplant (offen, noch nicht begonnen) | 3 | 0 | 3 |
| ⏸ bewusst verschoben | 0 | 2 | 2 |
| 👤 braucht Fuchs | 13 | 1 | 14 |
| 📱 nur am iPhone prüfbar | 2 | 1 | 3 |
| **Summe** | **81** | **39** | **120** |

Rund 23 Befunde stehen in beiden Listen (gleicher Fehler, zwei Nummern). Sie sind mit „= …“
markiert und haben in beiden Listen denselben Status, außer wo nur ein Teil gleich ist („⊂“).
Die Zusatzfunde Z1 bis Z3 sind alle erledigt.

## So benutzt du die Liste

- **Abhaken, sobald erledigt:** Status auf ✅ setzen und in „Beleg“ den Commit oder Test eintragen.
- ✅ steht nur da, wo ein Commit oder Test auf `integ/next` oder `main` liegt. Ein Fix, der nur auf
  einem lokalen Zweig liegt, ist 🔧 (der Zweig steht dabei). Unklar heißt: nicht erledigt.
- **Erst nachstellen, dann ändern (Fuchs, 19.11.):** Nicht jeder Befund der großen Analyse wurde
  doppelt geprüft. Der Leiter hat rund 30 selbst am Code nachgesehen, 19 sind durch einen roten Test
  belegt. Die 39 der Prüfung von außen wurden alle am Code geprüft (0 falsch). Deshalb wird jeder
  offene Befund vor der Korrektur mit einem Test nachgestellt, der rot ist. Lässt er sich nicht
  nachstellen, wird nichts geändert, und hier steht „❔ nicht nachstellbar“ mit dem Grund.
- 👤 heißt: Ohne dich geht es nicht weiter (eine Entscheidung, ein Klick bei GitHub oder ein Test
  am iPhone). Alle 👤-Punkte stehen unten noch einmal gesammelt.
- Die Nummern führen zum Befund: P… in `sortly-review/fable-analyse-2026-11-18/PRUEFER-*.md`,
  G… in `sortly-review/chatgpt-rueckgabe-2026-11-18/arbeitsstand/pruefer-a.md` und `pruefer-b.md`.
- „IMPROVEMENTS“, „DECISIONS“, „KNOWN_LIMITATIONS“, „TEST_PLAN“ meinen die Dateien in `docs/`.

## Große Analyse (Fable-Analyse, 81 Befunde)

### Prüfer 1: Kernlogik

| Nr. | Worum es geht | Status | Beleg |
|---|---|---|---|
| P1-01 | Häufiger Ort bekommt neue Kennung, Name und „Nicht jetzt“ gehen verloren (= G1-04) | ✅ | 868bc65, ba3da72; `FrequentPlaceIDTests`; DECISIONS „Kennung häufiger Orte“ |
| P1-02 | „Gleicher Name gewinnt“ nicht in allen Wegen: zweites Album „Italien“ wird angeboten | ✅ | `main` 5f9ad8a (PR #10): 7bda4b1, d224d4d, 2d02cca, 1423db5, 0e7a428; Tests `AlbumInterplayReviewTests` (theOnlyAlbumOfTheNameIsExtendedWhateverItHolds u. a.), zwei Zweitprüfungen |
| P1-03 | Fotos mit Datum in der Zukunft bleiben für immer „unsortiert“ | ✅ | `main` 5f9ad8a: 3785439; Test `NeverDoneTests.photosDatedInTheFutureCountLikeTheOthers` |
| P1-04 | Jahreszeiten auf der Südhalbkugel | ✅ | f44c59c; `NamingTests`; DECISIONS „Jahreszeiten mit Halbkugel“ |
| P1-05 | „Ignorieren“ macht den Ring schlechter, 100 % nie erreichbar | ✅ | 0a9f2d1, a3ba7ea; `RingDefinitionTests`; Entscheidung 1 |
| P1-06 | Liste „Sortiert“ zeigt andere Zahl als der Ring | ✅ | 0a9f2d1, a3ba7ea; `RingAndListTests`; Entscheidung 2 |
| P1-07 | Wechsel auf „Ausgewählte Fotos“ und zurück wirft die ganze Analyse weg | ✅ | fertig 20.11., drei Prüfungen, zuletzt ohne Befund; Reisen, Orte und ihre Namen bleiben über mehrere Auswahlen; Rückgängig braucht vollen Zugriff; in main seit PR #12 (fdf9c30), in Build 40 |
| P1-08 | Dreimal unlesbares Foto wird nie wieder versucht, Text verspricht „später noch einmal“ | ✅ | `main` 5f9ad8a: 6ed182e, e5c8635, afee52b (nach einer Woche neu versucht, der Text stimmt jetzt); Tests `NeverDoneTests.aPhotoGivenUpAsUnreadableIsTriedAgainAWeekLater` u. a. Wortlaut „N nicht lesbar“ kommt als Entwurf |
| P1-09 | Fotos auf See oder an der Grenze ohne Online-Ortssuche bleiben für immer „offen“ | ✅ | `main` 5f9ad8a: 8f8a5f4, d62de37; Tests `NeverDoneTests.photosThatCannotGetACountryAreNotCountedAsWaiting` u. a. |
| P1-10 | Das eigene Zuhause wird als „Häufiger Ort in München“ vorgeschlagen | 👤 | Entscheidung 7 (Album fürs Zuhause?) offen; Zuhause-Erkennung ist repariert (G1-02) |
| P1-11 | Krim, Westsahara usw. bekommen ein Land und gelten als „sicher“ | ✅ | d52cb53, a905af6, b376999, e627d49; `DisputedAreaTests`; Entscheidung 8 |
| P1-12 | Nach Sprachwechsel bleiben Ländernamen in der alten Sprache (⊂ G1-03) | ✅ | 6933ba5, 638ff85, daff055; `AlbumNameLanguageTests`. Rest Städte: G1-03 |
| P1-13 | Suche liest „seit/vor/nach 2024“ als genau 2024 (⊂ G1-06) | ✅ | e17d5e3, 60c8974, fcccf28; `SearchDateRangeTests`. Rest „Winter 2024“: G1-06 |
| P1-14 | Drei Fotos von zu Hause teilen eine Reise in zwei Alben | ✅ | 8118fcb, f103cf5, 71332f6; `TripHomeInterludeTests` |
| P1-15 | Tage und Monate hängen an der Zeitzone, auf die das Gerät gerade gestellt ist | ✅ | fertig und zweitgeprüft, in main seit PR #12 (fdf9c30, Mac-Lauf grün) In Build 40 (main fdf9c30, PR #12), Mac-Durchgang und Bildschirmfotos grün. |

### Prüfer 2: Schutz der Fotos

| Nr. | Worum es geht | Status | Beleg |
|---|---|---|---|
| P2-01 | Abbruch im falschen Moment: „Alles zurücknehmen“ lässt still etwas zurück | ✅ | 92ce693, bbcac5f; `UndoHardeningTests`, `InterruptionWaysOutTests` |
| P2-02 | Vorschau verspricht einen Namens-Zusatz, den es nicht gibt | ✅ | fertig, in main seit PR #12 (fdf9c30), in Build 40: Hinweis sagt „Danach hast du zwei Alben mit diesem Namen“ |
| P2-03 | Ortsnamen: Koordinaten gehen ab Werk an Apple, Start sagt „Nichts wird hochgeladen“ (= G2-02, G3-03) | ✅ | 752ba07, 8dbc5cc, 89bca6e; `PromiseWordingTests`; Entscheidung 3 |
| P2-04 | IBAN und Kartennummern bei unüblicher Schreibweise lesbar, Ausweis-Rückseite gespeichert (⊂ G2-03) | ✅ | 91f59c7, 3adf0ac, b2322be, 7655f45; `TextMinimizerTests` |
| P2-05 | Beispielfotos löschen: keine zweite Prüfung im Lösch-Block | ✅ | 23abd80; `SampleLibraryTests`; DECISIONS |
| P2-06 | Toter Weg „Quell-Alben entfernen“ hätte Alben ohne Lösch-Schutz gelöscht | ✅ | 6ccdf74; `PlanningExecutionTests` (`noPlanDeletesAnAlbumWithoutADeleteGuard`) |
| P2-07 | Journal einen Eintrag hinter Fotos: „Fortsetzen“ legt Alben doppelt an | ✅ | 6f699e0; `UndoHardeningTests`. Rest (`fullfsync`) nur am Gerät messbar, KNOWN_LIMITATIONS |
| P2-08 | Foto kommt kurz vor dem Löschen ins Album und verliert seine Zuordnung (= G2-01) | ✅ | 87e1094; `UndoHardeningTests.aPhotoThatComesInBeforeTheDeletionGoesOutKeepsTheAlbum` |
| P2-09 | Zwei Pläne ergänzen dasselbe Album, Rückgängig des älteren nimmt Fotos des neueren mit | 👤 | KNOWN_LIMITATIONS: zwei Wege möglich, „offen für eine Entscheidung“ |

### Prüfer 3: Bedienung und Design

| Nr. | Worum es geht | Status | Beleg |
|---|---|---|---|
| P3-01 | Knopf „aus Vorschlag entfernen“ liegt hinter der Tab-Leiste (= G3-04) | ✅ | fertig 20.11., zweite Prüfung ohne Muss-Punkt: Tab-Leiste im Auswahlmodus aus, Aktionen unten wie in Apple Fotos; neue CI-Regel; Bildschirmfotos für dich vor dem Zusammenführen; in main seit PR #12 (fdf9c30), in Build 40 |
| P3-02 | „Nichts wird hochgeladen“ passt nicht zum Ortsnamen-Schalter (= P2-03) | ✅ | wie P2-03 |
| P3-03 | Zu viele und widersprüchliche Zahlen zu „sortiert“ („0 von 0 sortiert“) | ✅ | fertig 20.11. (Zweig `fix/overviewnumbers`), zwei gründliche Prüfungen ohne Muss-Punkt: jedes Foto in genau einer Gruppe, Summe = Zahl der Analyse-Karte; nie mehr „0 von 0“; Bildschirmfotos für dich vor dem Zusammenführen In Build 40 (main fdf9c30, PR #12), Mac-Durchgang und Bildschirmfotos grün. |
| P3-04 | Erster Start zu lang: 4 Bildschirme, bis zu 7 Schalter, 150 Wörter | 📋 | löst das beschlossene Bedienungs-Paket A, noch nicht gebaut |
| P3-05 | „Alben jetzt anlegen“ erst nach Scrollen sichtbar (= G3-05) | ✅ | fertig 20.11. (Zweig `fix/plancta`), zweite Prüfung ohne Muss-Punkt: Knopf in einer Leiste unten, immer erreichbar; Bildschirmfotos für dich vor dem Zusammenführen In Build 40 (main fdf9c30, PR #12), Mac-Durchgang und Bildschirmfotos grün. |
| P3-06 | Ein Vorschlag hat bis zu sechs Aktionen | ✅ | fertig 20.11. (Zweig `fix/suggestactions`), zweite Prüfung ohne Muss-Punkt: zwei Knöpfe, der Rest oben rechts unter „…“; neue CI-Regel; Bildschirmfotos für dich vor dem Zusammenführen In Build 40 (main fdf9c30, PR #12), Mac-Durchgang und Bildschirmfotos grün. |
| P3-07 | Rückgängig später schwer zu finden, iOS-Löschfrage kommt unangekündigt (= G3-09) | ✅ | fertig 20.11., drei Prüfungen, zuletzt ohne Muss-Punkt: jede Rückfrage kündigt die Frage von iOS an (Alben frisch gelesen, höchstens 3 s, sonst sicher angekündigt); in main seit PR #12 (fdf9c30), in Build 40 |
| P3-08 | Analyse-Karte zeigt neun Dinge auf einmal | ✅ | fertig 20.11. (Zweig `fix/analysiscard`), zweite Prüfung ohne Muss-Punkt: Karte mit fünf Teilen, Rest in „Details“; Bildschirmfotos für dich vor dem Zusammenführen In Build 40 (main fdf9c30, PR #12), Mac-Durchgang und Bildschirmfotos grün. |
| P3-09 | Mehrere Wörter für dieselbe Sache | 🔧 | fertig und zweitgeprüft (Zweig `fix/wording`), am 20.11. an Design-Welle 1 übergeben (Zweig claude/project-thread-4i2bv6), kommt im neuen Look |
| P3-10 | Englisch mit Fehlern, z. B. „Safe“ statt „Certain“ (= G3-10) | ✅ | PR #11 (31ec24c): b5f7cee, `english_rule.py` |
| P3-11 | Größte Schrift: Länderliste im Reise-Atlas wird zerhackt (= G3-01) | ✅ | PR #11 (31ec24c): f3c061a, `checkAtlasRows` |
| P3-12 | Größte Schrift: Symbol überlappt Text in der Suche (= G3-07) | ✅ | PR #11 (31ec24c): fc41e52, `layout_rule.py` |
| P3-13 | Suche meldet „nicht erkannt“ neben einem Treffer-Vorschlag (= G3-06) | ✅ | PR #11 (31ec24c): 836c083 |
| P3-14 | Kleine graue Texte auf weißen Karten zu blass | ✅ | ein gemeinsamer Stil (`Theme.noteText`) und eine CI-Regel. In Build 40 (main fdf9c30, PR #12), Mac-Durchgang und Bildschirmfotos grün. |
| P3-15 | Titel bleibt „Vorschau“ auch während Sortier-Show und „Fertig“ | ✅ | fertig, in main seit PR #12 (fdf9c30), in Build 40: Titel folgt dem Schritt (`PlanReviewPhase`) |
| P3-16 | Im Tab „Alben“ stehen Alben doppelt (= G3-02) | ✅ | PR #11 (31ec24c): `AlbumTabSections`, DeviceCondition test07 |
| P3-17 | „Ordner für neue Alben“ schon bei normaler Schrift abgeschnitten (= G3-08) | ✅ | PR #11 (31ec24c): ab98c57, `checkFullyShown` |
| P3-18 | Sammlung kleiner Punkte (an Bildschirmfotos belegt) | 🔧 | größte Schrift („+N“, Sprung-Knopf) und „Gerade eben geprüft“ fertig (Zweige `fix/xxxl`, `fix/wording`), am 20.11. an Design-Welle 1 übergeben; dazu N-01, N-07, N-08 |

### Prüfer 4: Tempo und Stabilität

| Nr. | Worum es geht | Status | Beleg |
|---|---|---|---|
| P4-01 | „Ignorieren“ wirkt erst nach kompletter Neuberechnung (= G4-02) | ✅ | f42c48f, d71fcea (PR #7) |
| P4-02 | `refreshDerived` liest alles neu, einen Teil doppelt, der Start wartet darauf | ✅ | fertig und zweitgeprüft, in main seit PR #12 (fdf9c30), in Build 40 |
| P4-03 | Jeder Analyse-Lauf liest die ganze Mediathek neu, auch ohne Änderung | ✅ | fertig, zwei Zweitprüfungen ohne schweren Fehler, alle Punkte umgesetzt; in main seit PR #12 (fdf9c30), in Build 40 |
| P4-04 | Mediathek-Tab filtert und sortiert alle Fotos auf dem Haupt-Strang (= G4-01) | ✅ | 2960726, d71fcea (PR #7) |
| P4-05 | Am echten iPhone wird nichts gemessen, Diagnosebericht ohne Zeiten und Hänger | ✅ | `main` 5f9ad8a: Akku je 1.000 Fotos und MetricKit im Diagnosebericht (a4fc303, 68aec4c, ed66efd, 9e06bef); erste echte Zahlen mit dem nächsten Build (P4-08) |
| P4-06 | Speicher: mehrere volle Kopien, keine Reaktion auf Speicherwarnungen | ✅ | fertig und zweitgeprüft, in main seit PR #12 (fdf9c30), in Build 40 |
| P4-07 | „Pause in unter 1 Sekunde“ gilt nur für die Anzeige, nicht für die Arbeit | ✅ | fertig und zweitgeprüft, in main seit PR #12 (fdf9c30), in Build 40 |
| P4-08 | Erstes Lesen und Bilderkennung nur im Simulator gemessen (7,3 h für 50.000) | 📱 | braucht Messung am iPhone (kommt mit P4-05) |
| P4-09 | Weitere Rechnungen über alle Fotos auf dem Haupt-Strang | 🔧 | teilweise in main seit PR #12 (fdf9c30), in Build 40 (Rest offen): Zuhause-Kandidaten erst bei Bedarf, Vorberechnungen abseits des Haupt-Strangs Rest (Jahres-Atlas, Name des Zuhauses nur auf Abruf und abseits) in PR #13. |
| P4-10 | Schutz gegen veraltete Ergebnisse deckt nur die letzte Zuweisung (= G4-03) | ✅ | `main` 5f9ad8a: c7a21f9 und Folge-Commits (f4ce44e, 00c33c5); Tests `TripChangeLedgerTests` |
| P4-11 | Foto-Ansicht blättert über bis zu 3.000 Seiten | ✅ | PR #11 (31ec24c): `PageWindow` |
| P4-12 | Dauer-Animationen: Kosten für Akku und Wärme unbekannt | 📱 | erst am iPhone messen; Akku-Zahl kommt mit `feat/battery` |
| P4-13 | Im Hintergrund werden Screenshots viel langsamer gelesen | 👤 | deine 5-Minuten-Messung, danach Entscheidung 6 (Grafikeinheit) |

### Prüfer 5: Tests und Bau-Strecke

| Nr. | Worum es geht | Status | Beleg |
|---|---|---|---|
| P5-01 | Build 36 erst im dritten Versuch grün, das Tor merkt Wiederholungen nicht | ✅ | d94be53, 96fe370; `test_ci_gate.py`, `test_earlier_attempts.py` |
| P5-02 | Schalter „force“ lädt ohne Test hoch, Apple-Schlüssel ungeschützt (⊂ G5-02) | ✅ | „force“ weg (51e72f3), Umgebung `testflight-upload` von dir eingerichtet (19.11.), Upload ohne Klick nur von `main`; Beleg: TestFlight-Lauf 44541589587, Build 38 (Tag `build-38`), alle Tore grün beim ersten Versuch |
| P5-03 | Getestet wird nur die Debug-Fassung, die ausgelieferte Release-Fassung nie | ✅ | Rauchtest des Release-Builds vor dem Upload auf `main` (8304617, d159140); Beleg: TestFlight-Lauf 44541589587, Job „Release build smoke test (UI)“ grün vor dem Upload von Build 38 |
| P5-04 | Kein Zeitplan läuft (Nachtlauf, Härtetest, Abholen der Abstürze) | ✅ | Zeitpläne laufen auf `main`, alle grün am 20.11.: Nachtlauf (Lauf 44698348676), CodeQL (44705078341), Tages-Build (44732451070), TestFlight-Rückmeldungen seit 19.11. GitHub startet sie aber Stunden später als geplant (Nachtlauf 8:53 statt 2:00 Uhr); von Hand gestartet 5:16 Uhr ebenfalls grün |
| P5-05 | Bedienungs-Durchgang wartet vor allem, Demo-Mediathek wird in jeder Gruppe neu analysiert | 🔧 | Stufe 2, Teil 1 fertig 20.11. (Zweig `fix/sleeps`, zweite Prüfung bestanden): 61 von 70 festen Pausen in 4 Test-Dateien durch echtes Warten ersetzt; Teil 2 (Geräte-Tests) in Arbeit; Rest und Stufe 1 offen |
| P5-06 | 8 von 15 roten Durchgängen waren kein App-Fehler | ✅ | `main` 5f9ad8a: bedingte Wartezeiten (90c79c1), Home-Druck mit drei Wegen, jede Wiederholung gezählt; UI-Lauf 44529147724 auf PR #10 im ersten Versuch grün |
| P5-07 | Geplanter Umbau bringt nur 60 statt 84 Min. und macht die Bau-Strecke größer | 📋 | Stufe 4 (Tor vereinfachen, rund 1.400 Zeilen weg) offen |
| P5-08 | Das neue Tor hat eigene Lücken (a bis f) | ✅ | (a) „force“ weg, (b) = G5-04, (c) nur die Dateien der UI-Workflows zählen (IMPROVEMENTS), (d) keine Antwort der Log-Schnittstelle = kein Urteil (PR #11), (e) = P5-02, (f) = P5-03 (Release-Probelauf in jedem TestFlight-Lauf) |
| P5-09 | Tests laufen fast nie von selbst, Hauptzweig nicht geschützt (≈ G6-05) | 👤 | GitHub meldet am 19.11. „Branch not protected“: Schutz für `main` einschalten |
| P5-10 | Läufe für Build 36 prüften einen zusammengeführten Stand, nicht den ausgelieferten | ✅ | 3bad601 (TestFlight-Lauf testet seinen eigenen Commit), `archive_check.py` |
| P5-11 | 3 von 11 eingebauten Fehlern blieben in den schnellen Tests unentdeckt | ✅ | PR #11 (31ec24c): 7f1df09, `SeededFaultTests` |
| P5-12 | Schlüssel und fremde Pull Requests: drei offene Punkte | 👤 | CodeQL läuft wieder grün; offen: Dependabot (jetzt PR #8) und Freigabe für fremde Mitwirkende in den Einstellungen |
| P5-13 | Regel „nie still wiederholen“ gebrochen, Test vor dem Build gelockert | ✅ | PR #11 (31ec24c): Lint-Schritt „Zeitgrenze nur mit Eintrag lockern“ |
| P5-14 | Kleinere Punkte in den schnellen Tests (Dateinamen, Zeitmessungen, Zufall) | ✅ | fester Zufall und Zählung statt Zeit in PR #11 (31ec24c); Dateinamen nach Thema in main seit PR #12 (fdf9c30), in Build 40 |
| P5-15 | Alter Upload-Ablauf auf `main` lädt ungetestete Stände hoch (= P6-01, G5-01) | ✅ | 8b5afbd (PR #5, 6cdefb3); `test_workflows.py` |

### Prüfer 6: Vorgaben und Arbeitsweise

| Nr. | Worum es geht | Status | Beleg |
|---|---|---|---|
| P6-01 | Warnung „nichts auf main zusammenführen“ verschwunden (= P5-15) | ✅ | wie P5-15 |
| P6-02 | 53 Stunden kein Build: großes Tor vor jedem Build | ✅ | täglicher Build auf `main` seit PR #10, Umgebung eingerichtet; erster Lauf 20.11. 04:30 Uhr; erster Zeitplan-Lauf grün (20.11. 13:02 Uhr, Lauf 44732451070). |
| P6-03 | „Jedes Limit-Fenster voll nutzen“ und „Vollgas“ erzeugen Baustellen | 👤 | Entscheidung 11 (Vorgaben ändern nur du) |
| P6-04 | Zweitprüfung ohne Stopp-Regel (28 Prüfdurchgänge) | 👤 | Regeltext für die Vorgaben (Vorschlag von Prüfer 6) |
| P6-05 | Ziel und Ist stehen in den Vorgaben ununterscheidbar nebeneinander | 👤 | Regeltext; `main` ist seit PR #7 wieder aktuell |
| P6-06 | Kein Ort, an dem du den Stand siehst; Schätzungen lagen alle zu früh | 📋 | diese Liste ist ein erster Schritt, eine Stand-Seite fehlt |
| P6-07 | Einzelheiten der Bau-Strecke in den Vorgaben, nachts geändert | 👤 | Regeltext |
| P6-08 | Technik-Rückfragen an dich, App-Verhalten nachts ohne dich entschieden | 👤 | Entscheidung 13 |
| P6-09 | Regeln erreichen Unter-Agenten nur von Hand | 👤 | Regel-Datei im Repo (Entwurf von Prüfer 6) braucht dein OK |
| P6-10 | „Für jeden Fall einen Test“ nennt keine Ebene | 👤 | Regeltext; TEST_PLAN hat jetzt zwei Tore (96cef21) |
| P6-11 | Für 1.0 fehlen Umfangs-Stopp, Freigabe-Zahlen, echte Tester | 👤 | Entscheidung 12; Tester einladen kannst nur du |

## Prüfung von außen (ChatGPT-Rückgabe, 39 Befunde)

| Nr. | Worum es geht | Status | Beleg |
|---|---|---|---|
| G1-01 | Ganz weit im Norden kann ein Foto im Album „regelmäßiges Reiseziel“ fehlen | ✅ | `main` 5f9ad8a: 78daf4c; Test `GeoTests.spatialIndexFindsEveryNeighbourAtAnyLatitude` |
| G1-02 | Zuhause falsch erkannt (nur die ersten 15 Fotos je Tag) | ✅ | 243f6d2, 8b620eb; `HomeDayPointTests`; DECISIONS |
| G1-03 | Nach Sprachwechsel bleiben Städtenamen in der alten Sprache (⊂ P1-12) | ⏸ | bekannte Grenze, KNOWN_LIMITATIONS: braucht neue Ortsabfragen (Netz, Drosselung) |
| G1-04 | Zwei nahe Lieblingsorte bekommen dieselbe Kennung (= P1-01) | ✅ | 868bc65, ba3da72; `FrequentPlaceIDTests` |
| G1-05 | Suche findet selbst benannte Orte erst mit Album | ✅ | d97d340, 929088d; `NamedPlaceSearchTests` |
| G1-06 | „Winter 2024“ zeigt Jan/Feb und Dez 2024 (⊂ P1-13) | ⏸ | so entschieden (DECISIONS „Winter 2025 bleibt …“, zwei sichtbare Chips); Empfehlung zu Entscheidung 15: so lassen |
| G2-01 | Neues Foto hält Album beim Rückgängig nicht fest (= P2-08) | ✅ | 87e1094; `UndoHardeningTests` |
| G2-02 | Ortsnamen ab Werk an, Start sagt „Nichts wird hochgeladen“ (= P2-03, G3-03) | ✅ | 752ba07, 8dbc5cc; `PromiseWordingTests`; Entscheidung 3 |
| G2-03 | Arzt-Betreff gespeichert; englische Arztbriefe nicht erkannt (⊂ P2-04) | ✅ | deutsch 91f59c7; englisch 78fcb61, 9f92569, d942fd7; `TextMinimizerTests`, `DataSafetyTests` |
| G3-01 | Länderliste im Atlas bei größter Schrift zerstückelt (= P3-11) | ✅ | PR #11 (31ec24c): = P3-11 |
| G3-02 | Alben im Tab „Alben“ doppelt (= P3-16) | ✅ | PR #11 (31ec24c): = P3-16 |
| G3-03 | Start sagt „Nichts wird hochgeladen“ (= G2-02) | ✅ | wie G2-02 |
| G3-04 | Entfernen-Knopf hinter der Tab-Leiste (= P3-01) | ✅ | = P3-01, fertig, in main seit PR #12 (fdf9c30), in Build 40 |
| G3-05 | „Alben anlegen“ erst nach Scrollen sichtbar (= P3-05) | ✅ | = P3-05, fertig In Build 40 (main fdf9c30, PR #12), Mac-Durchgang und Bildschirmfotos grün. |
| G3-06 | Suche zeigt „nicht erkannt“ neben dem Vorschlag „Italien“ (= P3-13) | ✅ | PR #11 (31ec24c): = P3-13 |
| G3-07 | Symbol über dem Wort bei größter Schrift (= P3-12) | ✅ | PR #11 (31ec24c): = P3-12 |
| G3-08 | Ordner-Beschriftung abgeschnitten (= P3-17) | ✅ | PR #11 (31ec24c): = P3-17 |
| G3-09 | Rückgängig kündigt die iOS-Löschfrage nicht an (= P3-07) | ✅ | = P3-07, fertig, in main seit PR #12 (fdf9c30), in Build 40 |
| G3-10 | Englisch „SAFE“ missverständlich (= P3-10) | ✅ | PR #11 (31ec24c): = P3-10 |
| G4-01 | Mediathek sortiert auf der Oberfläche (= P4-04) | ✅ | 2960726, d71fcea |
| G4-02 | „Rückgängig“ nach Ignorieren kommt spät (= P4-01) | ✅ | f42c48f, d71fcea |
| G4-03 | Kurze Zwischenstände bei gleichzeitigen Neuberechnungen (= P4-10) | ✅ | = P4-10, `main` 5f9ad8a |
| G4-04 | Schneller Wechsel „dieses Jahr“/„alle“ speichert vielleicht den alten Umfang | 📱 | im Code kein Weg gefunden, nur am iPhone klärbar (TEST_PLAN F4) |
| G4-05 | Suche während eines Index-Neubaus nutzt einmal den alten Stand | ✅ | fertig, in main seit PR #12 (fdf9c30), in Build 40 |
| G5-01 = G6-01 | Alter Upload-Weg auf dem Hauptzweig (= P5-15) | ✅ | 8b5afbd (PR #5) |
| G5-02 = G6-02 | Notfall-Schalter „force“ noch drin (⊂ P5-02) | ✅ | 51e72f3, 4589064; `test_workflows.py`; DECISIONS „Kein Notfall-Upload ohne Tests“ |
| G5-03 = G6-03 | 10.000-Fotos-Test vor jedem Upload Pflicht | ✅ | PR #7 (`testflight.yml` ruft `ui-stress.yml`), 7078f50; Entscheidung 4 |
| G5-04 | Kommentaränderung hebt die Sperre eines roten Tests auf (⊂ P5-08) | ✅ | 3a75c78, 8f10fa1; `test_ui_groups.py`, `test_ui_evidence.py` |
| G5-05 | Quittungs-Zahl ohne eigenen Test | ✅ | 113ce47; `PlanReceiptAssignmentTests` |
| G5-06 | Barrierefreiheits-Prüfung kann ausfallen, Test bleibt grün | ✅ | 2f547ac |
| G5-07 | 10.000-Fotos-Test grün ohne Analyse und ohne Pause | ✅ | 29d52c2, 7e2439a |
| G5-08 | Übersprungene Testgruppe gilt als grün | ✅ | a9bd9d8; `test_ui_tests.py` |
| G5-09 | Kauf-Test merkt nicht, wenn die Freischalt-Karte fehlt | ✅ | 3219bb3, 1a99f2c |
| G5-10 | Rundgang prüft Zeilen nur in einer Liste streng | ✅ | 40d76f0; Beleg durch einen UI-Lauf steht noch aus |
| G6-04 | Hauptzweig ist 3 Tage alt | ✅ | PR #7 auf `main` (da79816, 19.11.); PR #9 wartet als Nächstes |
| G6-05 | Zweitprüfung nirgends nachweisbar (≈ P5-09) | 👤 | `main` nicht geschützt (Klick von dir); PR-Vorlage hat noch kein Feld für die Zweitprüfung |
| G6-06 | Testplan widerspricht sich (77 offene Fälle) | ✅ | 96cef21; TEST_PLAN „Tore“; DECISIONS „Zwei Tore“ |
| G7-01 | Store-Text verspricht Städte-Alben | ✅ | 752ba07; `PromiseWordingTests`; Entscheidung 14 |
| G7-02 | Featuring-Check nennt iPad, die App ist nur fürs iPhone | ✅ | PR #11 (31ec24c): 53bbac1 |

### Zusätzlich gefunden beim Nachprüfen (nicht mitgezählt)

| Nr. | Worum es geht | Status | Beleg |
|---|---|---|---|
| Z1 | Derselbe Ort zweimal vorgeschlagen („Bayern“ und „Häufiger Ort in Zwiesel“) | ✅ | 4778b94, 8329de1, 617a156; `SamePlaceOnceTests` |
| Z2 | Fester Ort heißt „Bayern“ statt nach der Stadt | ✅ | b8662c7; `RecurringPlaceNameTests` |
| Z3 | Alter Zweig `claude/sortly-app` startete bei jedem Push einen Upload | ✅ | 20.11. mit deinem OK: gesichert (`albumist-app/backup/claude-albumist-app-2026-11-20.bundle`), PR #1 geschlossen, Zweig von dir gelöscht |

## Was braucht Fuchs (alle 👤 auf einen Blick)

1. ~~**Freigabe vor dem Hochladen einrichten**~~: erledigt (19.11., Umgebung `testflight-upload`). Build 38 ging am 19.11. um 16:40 Uhr ohne Klick zu TestFlight (P5-02 ✅; P6-02 wartet auf den ersten Tages-Build am 20.11.).
2. **Hauptzweig `main` schützen** (Klick bei GitHub): P5-09, G6-05.
3. **Einstellungen bei GitHub:** Freigabe für Läufe aus fremden Kopien; Dependabot-PR #8 annehmen oder schließen: P5-12.
4. **Entscheidungen, die im Repo noch nicht festgehalten sind:** 6 Grafikeinheit (nach Messung, P4-13), 7 Album fürs Zuhause (P1-10), 9 „Merken“ oder „Auswählen“ (Paket 4A), 11 „Vollgas“/Limit (P6-03), 13 Technik beim Koordinator (P6-08), dazu P2-09 (zwei Pläne, ein Album).
5. **Am iPhone:** 5-Minuten-Messung Hintergrund (P4-13); lässt sich „… aus Vorschlag entfernen“ antippen (G3-04)?
6. **Vorgaben (Regeltext):** P6-04, P6-05, P6-07, P6-09, P6-10.
7. **Für 1.0:** Tester einladen, Freigabe-Zahlen (P6-11).
8. ~~Zweig `claude/sortly-app` und PR #1 löschen~~: erledigt 20.11. (Z3).
