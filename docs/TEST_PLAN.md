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

Stand: ✅ Kern und Oberfläche geprüft (oder die Oberfläche ist nicht betroffen) · 🟡 Kern
geprüft, Oberfläche fehlt noch · ❌ kein Test · 📱 nur auf dem iPhone prüfbar (TestFlight).
Bestandsaufnahme 15.11.2026 18:30 UTC. Nachgeführt 15.11. 19:10 UTC nach den Zusammenführungen
Rückgängig, Vorschläge, Analyse sowie Kauf und Daten. „in Arbeit“: ein Agent baut den Test gerade.

| Fall | Stand | Test heute | Lücke / in Arbeit |
|---|---|---|---|
| A1 Gerät warm / heiß | 🟡 | DeviceState: everyCombination, appRunsNeverEndBecauseOfTheDevice; FirstDeviceTest | UI-Schalter (in Arbeit); echte Wärme 📱 |
| A2 Akku, Stromsparmodus, Laden | 🟡 | DeviceState: everyCombination; FirstDeviceTest: pauseWhileWaiting… | UI-Schalter (in Arbeit) |
| A3 App verlassen und zurück | ✅ | UI test6 | — |
| A4 App beendet während der Analyse | 🟡 | AnalysisCoverage: runKilledMidwayGoesOnWithAReopenedDatabase; secondRunCountsOn… | UI: beenden und neu starten (in Arbeit) |
| A5 App beendet beim Umsetzen | 🟡 | UndoHardening: resumeAfterTheAppEndedRightAfterCreating…, interruptedUndoIsNotTaken…; UI test5 | UI test5 wird repariert (in Arbeit) |
| A6 Hintergrundzeit läuft ab | 🟡 | AnalysisReliability: controlPausesTheRunInProgress, pauseBeforeTheRunBeginsIsNotLost | UI-Schalter (in Arbeit) |
| A7 Fortschritt auf dem Sperrbildschirm | 📱 | — | Zustand per Diagnosebericht |
| A8 Speicher voll | 🟡 | DataSafety: fullDiskDuringAnalysisWrite…, …JournalWrite…, …Finalization…, …Restore… | UI-Schalter für die Meldung (in Arbeit) |
| A9 Offline | 🟡 | PlaceResolution: offline…; AnalysisReliability: runInTheAppGoesOnWhenTheGeocoderRefuses; PurchaseStoreKit: offlineSaysSo… | UI-Schalter (in Arbeit) |
| A10 Mitteilungen abgelehnt | ❌ | — | UI: „Nicht erlauben“ |
| A11 Kleine/große Geräte, Querformat | ❌ | — | zweites Simulator-Gerät (in Arbeit) |
| A12 Dunkelmodus | 🟡 | UI test2 | Prüfung im Barrierefreiheits-Test (in Arbeit) |
| A13 Sehr große Schrift | 🟡 | UI test2 | alle Bildschirme, abgeschnittener Text schlägt fehl (in Arbeit) |
| A14 VoiceOver / Prüfung | 🟡 | audit() in test1–7 | Befunde lassen den Test scheitern (in Arbeit) |
| A15 Weniger Bewegung | ❌ | — | Barrierefreiheits-Test (in Arbeit) |
| A16 Deutsch und Englisch | 🟡 | appShipsEnglish; ProposalCuration: englishTitles | UI-Lauf auf Englisch |
| A17 Zeitzonen, Zeitumstellung | ✅ | TripTimeZone: 11 Tests (Reise über Zonen, Rückkehr ohne Foto); ProposalCuration: aTripEndsOnTheDateWhereItEnded; dayTripUsesDestinationCalendar… | — |
| B1 Voller Zugriff | ✅ | UI test1 | — |
| B2 Nur ausgewählte Fotos | 🟡 | authorizationMapping; AnalysisCoverage: accessReducedToLimited… | UI über das echte Onboarding |
| B3 Zugriff abgelehnt | 🟡 | deniedAccessStopsImmediately | UI |
| B4 Zugriff im Lauf entzogen | 🟡 | AnalysisCoverage: accessRevokedDuringARunStopsCleanlyAndResumes | UI (in Arbeit) |
| B5 Leere Mediathek | 🟡 | AnalysisCoverage: emptyLibraryFinishes | UI-Schalter (in Arbeit) |
| B6 Winzige Mediathek | ✅ | ProposalCuration: tinyLibrary; AnalysisCoverage: fivePhotosFinish | — |
| B7 Riesige Mediathek | 🟡 | Load: 20.000 / 100.000; AnalysisCoverage: twoThousandPhotos… | Zeit und Speicher 📱 |
| B8 Nur Screenshots | ✅ | ProposalCuration: screenshotsOnly; modifiedScreenshot… | — |
| B9 Fotos ohne Ort | ✅ | ProposalCuration: noLocations; Trip/Analyzer/Search | — |
| B10 Nur Videos | ✅ | ProposalCuration: videosOnly; AnalysisCoverage: videosOnlyLibraryFinishes | — |
| B11 Fotos nur in iCloud | 🟡 | refinementReadsICloudOriginals… | UI-Schalter; echter Download 📱 |
| B12 Geteilte Mediathek | 📱 | — | — |
| B13 Ausgeblendete Fotos | ✅ | AnalysisCoverage: hiddenPhotosOnlyWhenTheUserLetsAlbumistSeeThem | — |
| B14 Serien, Live, Panorama, RAW | 🟡 | ProposalCuration: burstsLivePhotosAndPanoramas, aBurstIsOneMoment; mediaTypeCategories | RAW |
| B15 Fotos kommen/gehen während eines Laufs | ✅ | AnalysisCoverage: photosAddedAndDeletedDuringARun; removedAssetsDisappear | — |
| B16 Alben in der Fotos-App geändert | ✅ | Matching E/F, DecisionLifecycle | — |
| B17 Gleicher Name existiert | ✅ | ProposalCuration: titleTakenByAUserAlbumWithOtherContent; sameNameDifferentContent… | — |
| B18 Eigene Ordner | ✅ | existingFoldersAreReused…, undoKeepsFolders…, UndoHardening: undoOfAMoveRemovesTheFolders…, moveIntoAFolderThatWasDeleted… | — |
| B19 Album fehlt kurz in der Albenliste (iCloud gleicht nach dem Wiederherstellen noch ab) | 🟡 | PluginReviewSafety: albumMissingFromTheListIsCheckedOnItsOwnBeforeItCountsAsDeleted, emptyListOrAFailedLookUpRecordsNothing, undoWithoutTheAlbumsRecordUsesThePlansJournal | Abruf in der App nur im Simulator; echtes iCloud 📱 |
| B20 Zugriff nach dem Einstieg in den Einstellungen entzogen | 🟡 | PhotoAccessLoss: chosenYearStaysWhenAccessIsTakenAwayAndComesBack; PluginReviewSafety: startScreenAfterPhotoAccessWasTakenAway | UI: Bildschirm „Kein Zugriff auf deine Fotos“ (resetAuthorizationStatus); test09 der Gerätezustands-UI-Tests erwartet noch die Einführung |
| C1 Ein Album anlegen | ✅ | UI test1, scenarioI | — |
| C2 300 Alben | ✅ | UndoHardening: threeHundredAlbumsWithTwentyThousandPhotosRunAndUndo | — |
| C3 Abbruch bei jedem Schritt | ✅ | UndoHardening: interruptionAtEveryWriteResumesAndUndoesCleanly, undoInterruptedAtEveryWriteFinishesCleanly | Oberfläche: siehe A5 |
| C4 „Nicht erlauben“ beim Löschen | 🟡 | undoThatPhotosDidNotCarryOut…(.declined); UndoHardening: declinedDeletionStillTakes… | UI tippt „Nicht erlauben“ (in Arbeit); echte iOS-Frage 📱 |
| C5 Fotos-App löscht nicht | 🟡 | …(.silentlyIgnored); UndoHardening: incompleteReadAfterDeletionIsNotTakenAsProof | UI-Schalter (in Arbeit) |
| C6 Rückgängig nach eigenen Änderungen | ✅ | undoRevertsOnlyOwnChanges u. a. | — |
| C7 Zweimal / Rest rückgängig | 🟡 | UndoHardening: partialUndoThenTheRestThenNothing, undoOfAnAlreadyUndonePlanChangesNothing | UI-Knopf (in Arbeit) |
| C8 Rückgängig nach Update | ✅ | UndoHardening: undoOfAPlanStoredByAnOlderVersion; managedAlbumRecordsFromOlderVersions… | — |
| C9 Album über Albumist entfernen | 🟡 | UndoHardening: removingAManagedAlbumAndTakingItBack | UI |
| C10 Unterbrochenes Umsetzen rückgängig, iOS-Frage mit „Nicht erlauben“ beantwortet | 🟡 | PluginReviewSafety: declinedUndoOfAnInterruptedPlanKeepsItInTheHistory, completedUndoOfAnInterruptedPlanCancelsIt, interruptedPlanThatChangedNothingIsCancelled, keptAsIsKeepsAnAlbumWhoseCheckFailed | UI: Meldung und Verlauf danach; echte iOS-Frage 📱 |
| C11 Neues Umsetzen, solange ein unterbrochenes offen ist | 🟡 | PluginReviewSafety: newPlanWaitsWhileAnInterruptedPlanIsOpen | UI: Karte statt „Jetzt umsetzen“ |
| C12 Rest rückgängig, nachdem das erste Rückgängig ein entferntes Album zurückgeholt hat | 🟡 | PluginReviewSafety: secondUndoOfARemovalFillsTheAlbumTheFirstOneBroughtBack, albumBroughtBackAndDeletedByTheUserIsNotMadeAgain, secondUndoRespectsWhatTheUserTookOutOfTheAlbumBroughtBack | UI-Knopf (siehe C7) |
| C13 App endet, bevor ein Rückgängig seine Ergebnisse gespeichert hat | 🟡 | InFlightAlbums: undoCutOffBeforeItsResultsWereStoredIsNotTheUsersDeletion, interruptedPlanCountsFinishedOnesDoNot | UI: beenden und neu starten (siehe A5) |
| D1 Gratis-Grenze | ✅ | PurchaseRules: exactlyAtTheLimitIsAllowedOneMoreIsNot, planPassingTheLimitHalfWay…, interruptedPlanHoldsItsFreeAlbumsBack; UI test7 | — |
| D2–D5 Kaufen, Wiederherstellen, Abbruch, offline | 🟡 | PurchaseStoreKit (StoreKit-Testsitzung): buying…, purchaseFromAnotherDevice…, restoreWithoutPurchaseSaysSo, cancelled…, askToBuy…, failed…, offline…, refundLocksAgain | erster Lauf auf dem Cloud-Mac steht aus; echte Zahlung 📱 |
| E1 Kaputte Datenbank | ✅ | DataSafety: garbageFile…, truncatedFile…, damagedPageIsFoundAtLaunch, rebuildSetsTheDamagedFileAside…; UI test4 | — |
| E2 Migration alter Versionen | ✅ | DataSafety: everyOlderVersionMigratesWithItsDataIntact, migrationThatFailsHalfWayLeavesTheOldVersion | — |
| E3 Sicherung wiederherstellen | ✅ | UI test4, Store: backup…, DataSafety: emptyDatabaseNeverOverwritesAFullCopy, libraryStateOfTheCopyFollowsThePhotoAccess | — |
| E4 Zurücksetzen | ✅ | DataSafety: resetClearsTheAnalysisAndNothingElse, resetIncludingDecisionsLeavesNoJournalBehind | — |
| F1 Jede Wahl beim Einstieg | 🟡 | UI test1 | Varianten (in Arbeit) |
| F2 Jeder Bildschirm hin und zurück | 🟡 | UI test3 | tiefer, ohne Auslassliste (in Arbeit) |
| F3 Suche mit echten Anfragen | 🟡 | SearchQuerySet: 100 echte Anfragen (alle 100 finden, was sie sollen); SearchPerformance: 50.000 Fotos; SortlySearchUITests: 6 Anfragen in der UI | erster UI-Lauf steht aus |
| F4 Probejahr bleibt | 🟡 | trialYearIsKeptForLaterRuns, UI test6 | Neustart, Wahl im Onboarding |
| F5 Foto groß ansehen | 🟡 | UI test1 | Zoom |
| G1 Zweitwohnsitz, Pendeln, Ferienwohnung, lange Reise | 🟡 | RecurringPlace-Lebenslagen (18 Muster: Pendeln, Wochenendhaus, Ferienwohnung, Familie, Umzug, Semester, 6-Monats-Reise, Dienstreisen, Nomaden), TripTimeZone (11), RecurringPlacePipeline | UI-Frage „Bist du hier öfter?“ im UI-Lauf |

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
