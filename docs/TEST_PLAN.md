# Testplan

## Strategie
- **Kernlogik** (`SortlyCore`, `SortlyStore`, `SortlyEngine`): Swift-Testing-Suites, laufen
  bei jedem Push auf Linux und macOS. Plattformzugriffe sind durch Fakes ersetzt
  (`SortlyTestSupport`: In-Memory-Mediathek, Fake-Geocoder, Fake-Analyse, steuerbare Zeit).
- **App** (`App/SortlyTests`): Abbildung von PhotoKit-Typen, Prüfung der Bilderkennungs-
  Begriffe gegen Vision, Texte. Läuft im iOS-27-Simulator auf GitHub Actions (Image `xcode-27`).
- **Kein Test auf echten Geräten** bisher: Es steht weder ein Mac noch ein iPhone mit
  Entwicklerzugang zur Verfügung. Das wird in TestFlight nachgeholt.

## Abnahmeszenarien (automatisiert)
| Szenario | Test |
|---|---|
| Reise mit Datumsbereich, Rückkehr, Tagesausflug | `TripTests` |
| Wiederkehrende Orte, Umzug | `GeoTests`, `TripTests` |
| Vorhandenes Album vollständig / ergänzbar / größere Sammlung / Namenskonflikt | `MatchingTests` |
| Plan ohne zerstörende Operationen, Wiederanlauf, Rückgängig | `PlanningExecutionTests` |
| Vom Nutzer entfernte Fotos werden nicht erneut hinzugefügt | `PlanningExecutionTests` |
| Analyse pausiert und setzt fort, inkrementell, Probelauf | `PipelineTests` |
| Offline-Karte: Grenzregionen, Inseln, Meer | `OfflineWorldMapTests` |
| Drosselung, Backoff, Cache, Verfeinerung der Ortsbestimmung | `PlaceResolutionTests` |
| Suche, Statusberechnung, Empfehlungen | `ProposalAndSearchTests`, `StatusAndDecisionTests` |
| Migrationen, Massendaten | `StoreTests` |

## Abdeckung aller Fälle (Regel seit 15.11.2026)
Jeder Fall, der auf einem iPhone passieren kann, hat einen automatischen Test, der ihn herstellt
und das Ergebnis prüft. Ein Fall ohne Test ist offen; mit offenen Fällen geht keine Version zu
TestFlight. Neue Funktionen kommen gleich mit ihren Tests. Nur echte Wärme, echtes iCloud, die
echten iOS-Fragen und die Zeit auf einem Gerät bleiben für TestFlight.

Stand: ✅ voll geprüft · 🟡 nur Kernlogik oder ohne Prüfung des Ergebnisses · ❌ kein Test.
Bestandsaufnahme 15.11.2026 18:30 UTC, danach je Zusammenführung nachgeführt.

| Fall | Stand | Test heute | Lücke / in Arbeit |
|---|---|---|---|
| A1 Gerät warm / heiß | 🟡 | FirstDeviceTest: hotDevice…, warmDevice… | Regeln von DeviceConditions in den Kern, UI-Schalter |
| A2 Akku, Stromsparmodus, Laden | 🟡 | FirstDeviceTest: pauseWhileWaiting… | jede Kombination als Kerntest, UI-Schalter |
| A3 App verlassen und zurück | ✅ | UI test6 | — |
| A4 App beendet während der Analyse | 🟡 | secondRunCountsOn…, pauseAndResume… | neu geöffnete Datenbank, UI: beenden und neu starten |
| A5 App beendet beim Umsetzen | 🟡 | UI test5, scenarioJ | Fortsetzen und Rückgängig in der UI, Plan sicher unterbrechen |
| A6 Hintergrundzeit läuft ab | ❌ | — | UI-Schalter |
| A7 Fortschritt auf dem Sperrbildschirm | ❌ | — | nur iPhone; Zustand per Diagnose |
| A8 Speicher voll | ❌ | — | Kern: Schreibfehler; UI-Schalter |
| A9 Offline | 🟡 | PlaceResolution: offline… | UI-Schalter |
| A10 Mitteilungen abgelehnt | ❌ | — | UI: „Nicht erlauben“ |
| A11 Kleine/große Geräte, Querformat | ❌ | — | zweites Simulator-Gerät |
| A12 Dunkelmodus | 🟡 | UI test2 | Prüfung im Barrierefreiheits-Test |
| A13 Sehr große Schrift | 🟡 | UI test2 | alle Bildschirme, abgeschnittener Text schlägt fehl |
| A14 VoiceOver / Prüfung | 🟡 | audit() in test1–6 | Befunde lassen den Test scheitern |
| A15 Weniger Bewegung | ❌ | — | Barrierefreiheits-Test |
| A16 Deutsch und Englisch | 🟡 | appShipsEnglish | UI-Lauf auf Englisch |
| A17 Zeitzonen, Zeitumstellung | 🟡 | dayTripUsesDestinationCalendar… | Sommer-/Winterzeit, Reise über Zonen |
| B1 Voller Zugriff | ✅ | UI test1 | — |
| B2 Nur ausgewählte Fotos | 🟡 | authorizationMapping | UI über das echte Onboarding |
| B3 Zugriff abgelehnt | 🟡 | deniedAccessStopsImmediately | UI |
| B4 Zugriff im Lauf entzogen | ❌ | — | Kern + UI |
| B5 Leere Mediathek | ❌ | — | Kern + UI-Schalter |
| B6 Winzige Mediathek | 🟡 | (nebenbei) | Kern mit Prüfung der Vorschläge |
| B7 Riesige Mediathek | 🟡 | Load: 20.000 / 100.000 | Zeit und Speicher nur auf dem iPhone |
| B8 Nur Screenshots | 🟡 | modifiedScreenshot… | Vorschläge prüfen |
| B9 Fotos ohne Ort | ✅ | Trip/Analyzer/Search | Mediathek ganz ohne Ort |
| B10 Nur Videos | ❌ | — | Kern |
| B11 Fotos nur in iCloud | 🟡 | refinementReadsICloudOriginals… | UI-Schalter; echter Download nur iPhone |
| B12 Geteilte Mediathek | ❌ | — | nur iPhone |
| B13 Ausgeblendete Fotos | ❌ | — | Kern |
| B14 Serien, Live, Panorama, RAW | 🟡 | mediaTypeCategories | Kern |
| B15 Fotos kommen/gehen während eines Laufs | 🟡 | removedAssetsDisappear | während des Laufs |
| B16 Alben in der Fotos-App geändert | ✅ | Matching E/F, DecisionLifecycle | Beobachter der App |
| B17 Gleicher Name existiert | 🟡 | sameNameDifferentContent… | Plan und UI prüfen |
| B18 Eigene Ordner | ✅ | existingFoldersAreReused…, undoKeepsFolders… | — |
| C1 Ein Album anlegen | ✅ | UI test1, scenarioI | — |
| C2 300 Alben | 🟡 | JournalLoad: 200 Alben | 300 Alben, 20.000 Fotos, Rückgängig |
| C3 Abbruch bei jedem Schritt | 🟡 | scenarioJ, AuditRegression | jeder Schritt in einer Schleife |
| C4 „Nicht erlauben“ beim Löschen | 🟡 | undoThatPhotosDidNotCarryOut…(.declined) | UI tippt „Nicht erlauben“ |
| C5 Fotos-App löscht nicht | 🟡 | undoThatPhotosDidNotCarryOut…(.silentlyIgnored) | UI-Schalter |
| C6 Rückgängig nach eigenen Änderungen | ✅ | undoRevertsOnlyOwnChanges u. a. | — |
| C7 Zweimal / Rest rückgängig | 🟡 | partialUndoOffersTheRemainingRepair | zweimal, UI-Knopf |
| C8 Rückgängig nach Update | 🟡 | managedAlbumRecordsFromOlderVersions… | Rückgängig wirklich ausführen |
| C9 Album über Albumist entfernen | 🟡 | managedAlbumsAreRecorded… | UI |
| D1 Gratis-Grenze | 🟡 | Audit2Fix: FreeAlbums… | Grenze im Kern, gesperrter UI-Lauf |
| D2–D5 Kaufen, Wiederherstellen, Abbruch, offline | ❌ | — | StoreKit-Testkonfiguration |
| E1 Kaputte Datenbank | 🟡 | UI test4 | wirklich kaputte Datei |
| E2 Migration alter Versionen | 🟡 | version2Database… | v1 und v3 |
| E3 Sicherung wiederherstellen | ✅ | UI test4, Store: backup… | — |
| E4 Zurücksetzen | 🟡 | resetKeepsDecisionsByDefault | jede Rücksetzung tut, was sie sagt |
| F1 Jede Wahl beim Einstieg | 🟡 | UI test1 | Varianten |
| F2 Jeder Bildschirm hin und zurück | 🟡 | UI test3 | tiefer, ohne Auslassliste |
| F3 Suche mit echten Anfragen | 🟡 | Search: countryAndYear u. a. | 40+ Anfragen, UI prüft Ergebnisse |
| F4 Probejahr bleibt | 🟡 | trialYearIsKeptForLaterRuns, UI test6 | Neustart, Wahl im Onboarding |
| F5 Foto groß ansehen | 🟡 | UI test1 | Zoom |
| G1 Zweitwohnsitz, Pendeln, Ferienwohnung, lange Reise | ❌ | — | eigene Lebenslagen-Tests |

## Testdaten
Synthetische Bibliotheken (Koordinaten, Zeitstempel, Alben) in `Fixtures.swift`.
Echte Testbilder nur mit freier Lizenz (CC0/gemeinfrei) und Lizenzliste.

## Gemessene Ergebnisse (Stand 2026-11-13)
- 143 Kern-Tests grün (Linux, Swift 6.2.3; macOS, Xcode 27).
- App-Build und App-Tests grün im iOS-27-Simulator (Xcode 27).
- 20 000 Fotos in die Datenbank schreiben: 0,33 s (Linux-Container).
- 500 Offline-Kartenabfragen: ca. 0,6 s.
- Vision kennt im Simulator 1303 Begriffe; alle Begriffe der Taxonomie sind darin enthalten.

## Offen
Messung der Analysezeit auf echten Geräten mit 15 000+ Fotos, Speicherverbrauch,
Wärmeverhalten, iCloud-Downloads, VoiceOver-Durchgang.
