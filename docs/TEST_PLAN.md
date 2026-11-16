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
| A7 Fortschritt auf dem Sperrbildschirm | 🟡 | ContinuedTaskHeartbeat (Linux); App: ContinuedAnalysisIdentifierTests, ContinuedAnalysisEndingTests (fertig, pausiert, Gerät/iOS, Fehler nach fertigem Lauf) | echtes Anzeigen nur am iPhone, Zustand per Diagnosebericht |
| A8 Speicher voll | 🟡 | DataSafety: fullDiskDuringAnalysisWrite…, …JournalWrite…, …Finalization…, …Restore…; OpenPlans: planFailingHalfWayIsOfferedAtOnceAndTheSamePlanWaits | UI-Schalter für die Meldung (in Arbeit) |
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
| B16 Alben in der Fotos-App geändert | ✅ | Matching E/F, DecisionLifecycle; ManagedAlbumCheck: whatTheUserChangedIsRecorded, limitedAccessComparesNothing | — |
| B17 Gleicher Name existiert | ✅ | ProposalCuration: titleTakenByAUserAlbumWithOtherContent; sameNameDifferentContent… | — |
| B18 Eigene Ordner | ✅ | existingFoldersAreReused…, undoKeepsFolders…, UndoHardening: undoOfAMoveRemovesTheFolders…, moveIntoAFolderThatWasDeleted… | — |
| B19 Album fehlt kurz in der Albenliste (iCloud gleicht nach dem Wiederherstellen noch ab) | 🟡 | PluginReviewSafety: albumMissingFromTheListIsCheckedOnItsOwnBeforeItCountsAsDeleted, emptyListOrAFailedLookUpRecordsNothing, albumWithoutARecordIsTheUsersOnlyAPlanNeverRecordedGoesByItsJournal; ManagedAlbumCheck: albumOnlyTheListLacksIsLookedUpOnItsOwn | Abruf in der App nur im Simulator; echtes iCloud 📱 |
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
| C10 Unterbrochenes Umsetzen rückgängig, iOS-Frage mit „Nicht erlauben“ beantwortet | 🟡 | PluginReviewSafety: declinedUndoOfAnInterruptedPlanKeepsItInTheHistory, completedUndoOfAnInterruptedPlanCancelsIt, interruptedPlanThatChangedNothingIsCancelled, keptAsIsKeepsAnAlbumWhoseCheckFailed, rueckgaengigOnAnInterruptedPlan (fertig, „Nicht erlauben“, vor dem ersten Schritt abgelehnt, Ergebnisse nicht gespeichert, abgebrochen), onlySuggestionsThePlanCarriedOutLeaveTheSelection; OpenPlans: appEndingRightAfterRueckgaengigLosesNothing, receiptAfterRueckgaengigEndedEarly | UI: Meldung und Verlauf danach; echte iOS-Frage 📱 |
| C11 Neues Umsetzen, solange ein unterbrochenes offen ist (auch eines, das in derselben Sitzung halb fehlschlug) | 🟡 | PluginReviewSafety: newPlanWaitsWhileAnInterruptedPlanIsOpen; OpenPlans: planFailingHalfWayIsOfferedAtOnceAndTheSamePlanWaits, settlingOneOfTwoOpenPlansOffersTheOther | UI: Karte statt „Jetzt umsetzen“ |
| C12 Rest rückgängig, nachdem das erste Rückgängig ein entferntes Album zurückgeholt hat | 🟡 | PluginReviewSafety: secondUndoOfARemovalFillsTheAlbumTheFirstOneBroughtBack, albumBroughtBackAndDeletedByTheUserIsNotMadeAgain, secondUndoRespectsWhatTheUserTookOutOfTheAlbumBroughtBack, secondUndoRespectsWhatTheUserTookOutOfAnAlbumTheFirstOneFilled | UI-Knopf (siehe C7) |
| C13 App endet, bevor ein Rückgängig seine Ergebnisse gespeichert hat | 🟡 | InFlightAlbums: undoCutOffBeforeItsResultsWereStoredIsNotTheUsersDeletion, interruptedPlanCountsFinishedOnesDoNot; ManagedAlbumCheck: checkAnswersTheSameBeforeAndAfterAPlansResultsAreStored (beide Reihenfolgen beim Start); OpenPlans: plansAwaitingTheirResults | UI: beenden und neu starten (siehe A5) |
| C14 Fotos von Hand zurückgelegt, nachdem „Album entfernen“ oder ein erstes Rückgängig sie herausgenommen hat, dann Rückgängig | 🟡 | PluginReviewSafety: undoAfterRemovalKeepsPhotosTheUserPutBackByHand, undoAfterRemovalDoesNotDeleteAnAlbumTheUserRefilled, restUndoKeepsPhotosTheUserPutBackAfterAPartialUndo | UI |
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
| F6 Sortiert-Ring mit eigenen Alben (Gerätetest 15.11.: 811, dann 157) | 🟡 | SortedCount: eigene Reisealben zählen für ihr Land, Zuhause zählt nicht für Länder und Orte, Neuaufbau, zweiter Lauf, Übernehmen und Rückgängig, „Nicht jetzt“ und „Albumists Fotos herausnehmen“, leere Mediathek, eingeschränkter Zugriff, 100.000 Fotos, alter Stand lädt, mehrere gleich gut passende Alben zählen alle, neue Fotos nach einer Reise bleiben unsortiert im Ring | Ring-Text und Diagnosezeile nur syntaxgeprüft; Zahl auf dem iPhone 📱 |
| G1 Zweitwohnsitz, Pendeln, Ferienwohnung, lange Reise | 🟡 | RecurringPlace-Lebenslagen (18 Muster: Pendeln, Wochenendhaus, Ferienwohnung, Familie, Umzug, Semester, 6-Monats-Reise, Dienstreisen, Nomaden), TripTimeZone (11), RecurringPlacePipeline | UI-Frage „Bist du hier öfter?“ im UI-Lauf |
| G2 Zuhause bestätigen, ändern, „Kein Zuhause“ | 🟡 | HomeAtDate: nothingSetLeavesEveryDateToTheDetection, chosenHomeHoldsForEveryDate, confirmedHomeHoldsFromTheConfirmation, noHomeHoldsForEveryDate; HomeTrip: confirmingTheDetectedHomeChangesNothing, confirmingAfterAMoveChangesNothing, noHomeMeansNoPhotoIsAtHomeButTripsStay, chosenHomeWinsOverTheDetection; HomeNaming: placeAlbumsOfTheHomeFollowTheSettings, aCountryAcrossTheBorderInsideTheHomeIsNoAlbum; Review: stimmtAfterAMoveChangesNothing, stimmtAfterAMoveAddsNoTrip, confirmingFromTheDetectedSinceWouldMakeTheLastWeeksATrip, chosenHomeWithoutItsTownNameKeepsTheHomeOutOfPlaceAlbums; Re-Review („Ändern“ nach einem Umzug): pickingTheNewTownUnderAendernKeepsThePastAsItWas, confirmedEarlierThenPickedTheNewTownKeepsTheConfirmedYears, theStayStartsAfterTheLastLongStretchElsewhere, pickingTheNewTownAddsNoTrip, homePlacesAreWorkedOutOncePerPlace; Runde 3 (Beginn des Aufenthalts): visitsBeforeTheMoveDoNotPullTheStayStartBack (alle 14 und 21 Tage), sparsePhotosAtHomeKeepTheStayFromItsStart, threeWeeksAwayKeepTheStayAMonthEndsIt, visitsBeforeTheMoveAddNoTripAfterPickingTheNewTown; HomePipeline: ringCountsTheHomeTheUserChose; HomeSearch: abroadFollowsTheHomeOfEachDate; App: HomeTextTests | Bildschirm „Dein Zuhause“ im UI-Lauf |
| G3 Umzug: früheres Zuhause mit Zeitraum, Überschneidungen | 🟡 | HomeAtDate: formerHomesFormAChain, overlapIsDecidedForThePeriodThatEndsFirst, formerHomeAndNoHomeNow; HomeTrip: tripsAreJudgedAgainstTheHomeOfTheirTime; HomeNaming: tripNamesUseTheHomeOfTheTripsTime, tripSuggestionsAreNamedWithTheHomeAtTheirStart; HomeCandidate: aRegionIsPlacedWhereItsPhotosAreDensest; HomePipeline: formerHomeBringsBackTheTripBeforeTheMove | UI-Lauf |
| G4 Eigene Orte („Eltern“, „Arbeit“, eigener Name) sind keine Reisen | 🟡 | HomeTrip: staysAtAPlaceOfTheUsersAreNoTrips; HomeSettingsStorage: personalPlaceKeepsItsIdAndTakesTheUsersName; HomePipeline: chosenSuggestionIsHeldAndTheOverviewIsTold | UI-Lauf |
| G5 Änderung am Zuhause macht nur die Vorschläge neu: keine Bildanalyse, kein Album, Auswahl bleibt, Übersicht sagt, was wegfiel – auch wenn ein Lauf, ein Neustart oder ein Fehler dazwischenkommt | 🟡 | HomePipeline: resuggestReadsNoPhotoAndTouchesNoAlbum, chosenSuggestionIsHeldAndTheOverviewIsTold, changingBackLeavesNothingToSay, withoutSuggestionsResuggestWaitsForTheAnalysis; Review: homeChangeAppliedByARunKeepsTheChosenSuggestion, runDuringAHomeChangeHoldsTheChoiceAndTellsTheOverview, ReReviewHomeTests.aNeinWhileTheSuggestionsAreMadeHoldsBackTheNotice, heldSuggestionDropsDeletedPhotos, rebuildWaitsForResuggestAndLeavesAFreshStore, ReReviewHomeTests.rematchDuringRebuildLeavesNoOldSuggestions, HomeChangeMarkTests.suggestionsFinishingWhileAChangeIsStoredKeepTheMark | Karte „Zuhause geändert“ im UI-Lauf |
| G6 Zuhause-Einstellungen gespeichert, alte Stände lesbar, übersteht „Analyse neu aufbauen“ und Sicherung | ✅ | HomeSettingsStorage: roundTrip, olderAndNewerValuesStayReadable, olderPlaceAnswersStayReadable; HomePipeline: settingsAreStoredKeptByARebuildAndInTheBackup, olderStoredValueIsRead; Review: unreadableHomeValuesDoNotStopTheAnalysis, ReReviewHomeStoreTests.damagedHomeBytesDoNotStopTheAnalysis | — |

## Fortschrittsanzeige der Analyse (Branch `claude/pro-progress`, Plan vom 15.11.2026)
Entwurf v3 (`progress-display/ENTWURF.md`) mit den 5 Punkten. Die Regeln liegen als reine Typen in
`SortlyEngine/AnalysisDisplay.swift` (Schritte, Breiten, `ProgressEstimator`, `BarGlide`,
`AnalysisCardState`, `AlreadyDone`, `ProgressMailbox`); die App zeigt nur deren Ergebnis.
Messbare Grenzen (vom Produktverantwortlichen, 15.11.): Pause zeigt in unter 1 s eine Reaktion;
keine Zahl und keine Uhrzeit steht länger als 10 s still, solange gearbeitet wird (Balken gleitet
oder eine Statuszeile bewegt sich); keine Zahl geht zurück; nichts zeigt „fertig“ oder eine volle
Zahl, solange noch gearbeitet wird.

| Fall | Test (Linux) | Nur in der App / am iPhone |
|---|---|---|
| P1 Pause: sofort „Wird angehalten …“, nach 10 s „Dauert noch einen Moment.“, dann „Analyse pausiert“ an der Stelle | AnalysisDisplayTests: pauseReactsAtOnceAndSaysMoreAfterTenSeconds, pausedByUserShowsWhereItStopped; FullRunDisplay (b): Pause endet in 1 Foto + 2 s | Karte (UI-Test analysis.pause) |
| P2 Sperren / Hintergrund ohne iOS-Aufgabe | AnalysisDisplayTests: tenMinutesInTheBackgroundDoNotCount; FullRunDisplay: backgroundGapResettles | Chip nur bei laufender Aufgabe 📱 |
| P3 App mitten im Lauf beendet und neu gestartet | AnalysisDisplayTests: widthsSurviveAsStored; FullRunDisplay (c): Balken mit festgehaltenen Breiten geht nie zurück | — |
| P4 App-Wechsel (nicht aktiv) | AnalysisDisplayTests: glideStopsWhenNotGliding | — |
| P5 Wärme: warm (langsamer), sehr warm (wartet), kritisch | DeviceStateTests: slowerReason…; AnalysisDisplayTests: waitingHasNoFinishTimeAndSettlesAgain, speedChangeMovesTheTimeOnlyPastTheHysteresis; FullRunDisplay (e) | echte Wärme 📱 |
| P6 Akku unter 10 % | DeviceStateTests: slowerReason…; AnalysisDisplayTests: cardStates | — |
| P7 Stromsparmodus | DeviceStateTests: slowerReason… | — |
| P8 Leere Mediathek | AnalysisDisplayTests: emptyLibraryWidths; FullRunDisplay: emptyLibraryShowsNoTime | — |
| P9 Riesige Mediathek (50.000) | AnalysisDisplayTests: fiftyThousandPhotosStayBoundedAndAccurate | Zeit am Gerät 📱 |
| P10 Kein / eingeschränkter Zugriff, Zugriff im Lauf entzogen | AnalysisDisplayTests: accessLostIsNotPausedNorFinished | — |
| P11 Analysefehler (Vision fällt aus) | AnalysisDisplayTests: finishMomentOnlyForACompleteLongRun | — |
| P12 Zweiter Lauf, „Neu prüfen“, „Analyse neu aufbauen“ | AnalysisDisplayTests: quickCheckShowsPauseAfterFiveSeconds; FullRunDisplay (d), (f) | — |
| P13 Nichts steht länger als 10 s still | FullRunDisplay: Invariante 8 (Zahl, Wartezeit oder gleitender Balken ändert sich alle 10 s) | — |
| P14 Fertig-Uhrzeit: erst verlässlich, nie beim Warten, ändert sich erst ab 2 Min., gerundet, morgen/Wochentag | AnalysisDisplayTests: noTimeBeforeThirtySecondsAndTwentyItems, roundingAndSoon, dayOfFinish; FullRunDisplay: Invariante 9 (Uhrzeit nahe am echten Ende) | Anzeige 📱 |
| P15 Gleitender Balken: nie zurück, höchstens 1 % voraus | AnalysisDisplayTests: glideNeverBackNeverAheadMoreThanOnePercent; FullRunDisplay: Invariante 3 mit Gleiten | — |
| P16 „Schon fertig“: erst ab Bildinhalten, Vorschläge stabil | AnalysisDisplayTests: alreadyDoneCounts; FullRunDisplay: earlyProposalsKeepTheirIDs | „Ansehen“ öffnet die Liste (UI-Test analysis.showDone) |
| P17 Fertig-Moment und Mitteilung „Vorschläge prüfen“ | AnalysisDisplayTests: finishMomentOnlyForACompleteLongRun | Haptik, Mitteilungsknopf 📱 |
| P18 Sperrbildschirm „2.431 von 5.683 Fotos · fertig gegen 23:40“, Ende „Analyse fertig“ / „216 Vorschläge“ | — | App-Test ContinuedAnalysisEndingTests (nur Syntax geprüft) |
| P19 (Review I2) „Schon fertig“ erscheint im ersten Lauf: Meldung, sobald die frühen Vorschläge gespeichert sind | FullRunDisplay: earlySuggestionsAreSaidOnceSaved | Tick liest sie dann, sonst alle 10 s erneut (nur Syntax) |
| P20 (Review I3) Balken steht beim Wechsel der Breiten nicht still, kein Abschnitt geht zurück | FullRunDisplay: Invariante 3 je Abschnitt, wie AppModel (Marker, shownOverall, Neustart des Gleitens) | — |
| P21 (Review I4) keine Uhrzeit, bevor das Gerät gemessen ist; Genauigkeit auf einem langsameren Gerät | AnalysisDisplayTests: noFinishTimeBeforeTheDeviceIsMeasured; FullRunDisplay: uninterruptedFullRun (≤ max(2 Min., 10 %)) | — |
| P22 Kleinere Punkte: entschiedene frühe Vorschläge bleiben, „Gleich fertig“ bleibt nicht hängen, kein Rücksprung nach Fortsetzen, kein Lichtstreif bei Apples Wartezeit, Foto-Mosaik nur bei der ersten Analyse | FullRunDisplay: decidedEarlySuggestionsStay; AnalysisDisplayTests: gleichFertigDoesNotLinger, glideGoesOnFromTheBarDrawnLast, cardStates, mosaicOnlyOnTheFirstAnalysis | Zeitumstellung, Fertig-Moment nach Hintergrund, Neuzählung erst mit vollem Stand 📱 (nur Syntax) |

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

## Design-Prüfung mit den Plugins (15.11.2026, Branch `claude/pro-design2`)
Befunde aus `design-plugin-review-2026-11-15/BEFUNDE.md`. „UI“ heißt: Schritt im UI-Lauf, der auf
dem Cloud-Mac noch laufen muss; bis dahin ist die Oberfläche nur syntaktisch geprüft.

| Fall | Stand | Test | Lücke |
|---|---|---|---|
| D1 Abzeichen „Name fehlt“ lesbar (Warnfarbe der App statt Systemorange) | 🟡 | Kontrast-Audit der Vorschlagsliste (AccessibilityUITests), wenn die Beispiel-Mediathek einen Ort ohne Namen hat | UI-Lauf |
| D2 Fehlertext in Primärfarbe mit rotem Symbol (`ErrorNote`) | 🟡 | — | UI-Schalter für einen Kauffehler fehlt |
| D3 Fotos eines Vorschlags sind benannte Knöpfe, „Ausgewählt“ für VoiceOver | 🟡 | UI test1: „suggestion photos are named buttons“, `isSelected` | UI-Lauf |
| D4 Ignorieren zurücknehmen: „Widerrufen“ direkt danach, „Nicht mehr ignorieren“ in „Ignoriert“ und im Foto | 🟡 | IgnoreUndoTests (5: nur Neues wird zurückgenommen, keine Doppelten, andere Entscheidungen bleiben, Status kehrt zurück); UI test1 `ignoreAndUndo` | UI-Lauf |
| W1 Originale: „Kein Original gelöscht“ statt „0 Originale gelöscht“ (Vorschau, Änderungen, geteilte Liste) | 🟡 | UI test1 sucht „Kein Original gelöscht“ | UI-Lauf |
| W2 Ein Name für den Vorgang: „Vorschau“, „Das ändert sich in Fotos“, „Alben jetzt anlegen“ (`plan.apply`), „Anlegen wurde unterbrochen“, „Änderungen“ | 🟡 | UI test1, test5, Locked, Accessibility (neue Titel und `plan.apply`) | UI-Lauf |
| W4 „Fotos“ statt „Aufnahmen/Bilder/Medien“ | ✅ | StringCatalogTests.photosAreCalledFotos (nur ScanShow ausgenommen, wird auf `claude/pro-progress` neu gebaut) | — |
| W5 Mehrzahl in Zählungen (auch mehrere Zahlen über Substitutionen) | ✅ | StringCatalogTests: everySubstitutionIsDefined, countVariesByPlural (11 Texte) | Anzeige im Simulator |
| W6 Suchbeispiele übersetzt und in beiden Sprachen verstanden | ✅ | SearchExampleTests (12 Beispiele, gleiche Treffer DE/EN, Liste = App und Katalog) | — |
| W17 Unterbrochen: „Rest anlegen“, „Alles zurücknehmen“, „Nur Erledigtes behalten“ (Rückgängig: „Rest zurücknehmen“, „So lassen“) | 🟡 | UI test5 (`interrupted.keep`) | UI-Lauf |
| W7/W18 Grauer Suchbegriff und „REISEN · SICHER“ auf der Fotofarbe in `Theme.secondaryText` | 🟡 | Kontrast-Audit Suche und Vorschlag (AccessibilityUITests) | UI-Lauf |
| W8 Lange Suchbegriffe brechen bei großer Schrift im Chip um | 🟡 | Baum-Prüfung „Text läuft aus dem Bildschirm“ (AccessibilityUITests, größte Schrift) | Anfrage mit langem Zeitraum im UI-Lauf fehlt |
| W9 Tippflächen 44 pt (Mediathek-Filter, Atlas-Jahre, Zuverlässigkeit, Kauf wiederherstellen/Code, Verlaufszeile) | 🟡 | `hitRegion`-Audit (AccessibilityUITests) | UI-Lauf |
| W10 Überschriften für VoiceOver („Bereiche“ als Text, Kartentitel) | 🟡 | — | VoiceOver-Rotor 📱 |
| W11 Großansicht mit System-Toolbar, nach unten wischen schließt, Datum/Ort für VoiceOver, „nicht verfügbar“ statt Endlos-Kreis | 🟡 | UI test1 „pull down closes the photo“; AccessibilityUITests „photo viewer“ | Foto nur in iCloud 📱 |
| W12 Tippen öffnet überall die Großansicht, Infos hinter „i“; Album zeigt alle Fotos | 🟡 | UI test1 „photo info“, „album photo opens large“ | UI-Lauf |
| W13 Einführung mit Zurück (Navigation) | 🟡 | UI test1 „onboarding back to areas“ | UI-Lauf |
| W16 Einstellungen: „Verlauf und Rückgängig“ als erste Zeile, „Zählt als sortiert“, „Ordner für neue Alben“ | 🟡 | UI test1, test4, test5 über `settings.history`; AccessibilityUITests „history“ | UI-Lauf |
| N1 Tab „Alben“ mit `rectangle.stack` wie in Fotos | 🟡 | — | Sichtprüfung 📱 |
| N2 Startbildschirm: VoiceOver sagt „Albumist wird geladen“ | 🟡 | — | VoiceOver 📱 |
| N3 „Animation überspringen“ als normaler Zweitknopf statt Glas im Inhalt | 🟡 | — | Sichtprüfung |
| N4 Albumcover = neuestes Foto | ✅ | DesignReviewMinorTests.albumCoverIsTheNewestPhoto (`PreviewPicker.newest`) | — |
| N5 „Vielleicht passend: 12 Fotos“ | 🟡 | — | Sichtprüfung |
| N6 Hinweis „Wähle mindestens einen Bereich.“ unter „Weiter“ | 🟡 | — | UI-Lauf |
| N8 Hinweis, warum nur „Ja“ wartet (Analyse oder Anlegen läuft) | 🟡 | — | Frage während einer Analyse 📱 |
| N9 „Alben von Albumist“ (auch ergänzte Alben) | 🟡 | — | Sichtprüfung |
| N10 Mediathek und Suche laden weitere Fotos beim Scrollen (`library.loadingMore`, `search.loadingMore`) | 🟡 | — | Mediathek mit über 3.000 Fotos 📱 |
| N11 Weltanteil im Format der Sprache, ein Land ist nicht „0 %“ | ✅ | DesignReviewMinorTests.worldShareKeepsSmallSharesAndTheLocaleStyle | — |
| N12 Leere Album-Suche mit `ContentUnavailableView.search` | 🟡 | — | UI-Lauf |
| N13 „Ähnliche Alben“: Ladekreis (`merge.preparing`), bis die Vorschau fertig ist | 🟡 | — | Mediathek mit ähnlichen Alben 📱 |
| N14 „Suchbegriff nicht erkannt“ | 🟡 | — | UI-Lauf |

## Dein Zuhause (Branch `claude/pro-home`, 16.11.2026)
Eine Funktion entscheidet, wo Zuhause an einem Datum war: `HomeSettings.home(at:)`
(`Sources/SortlyCore/Trips/Home.swift`). Reisen und der Ring fragen sie über `HomeReference`
(TripDetector), Reisenamen und Orte-Vorschläge über `HomeContext` (ProposalEngine). Ohne
Einstellung entscheidet die Erkennung wie bisher (Tests der Reisen und Vorschläge unverändert grün).

| Regel | Test (Linux) |
|---|---|
| Nichts eingestellt: jedes Datum geht an die Erkennung | HomeAtDateTests.nothingSetLeavesEveryDateToTheDetection |
| Unter „Ändern“ gewähltes Zuhause gilt ab „Seit wann wohnst du dort?“ (vorgeschlagen: Beginn des letzten Aufenthalts dort), davor die Erkennung; auch nach einem früher bestätigten Zuhause wird die alte Stadt keine Reise | ReReviewChangeAfterAMoveTests.pickingTheNewTownUnderAendernKeepsThePastAsItWas, confirmedEarlierThenPickedTheNewTownKeepsTheConfirmedYears, theStayStartsAfterTheLastLongStretchElsewhere; ReReviewChangeAfterAMovePipelineTests.pickingTheNewTownAddsNoTrip |
| Beginn des Aufenthalts: nur Tage mit Fotos zählen; er endet an 28 Fototagen, von denen mindestens vier von fünf woanders sind. Besuche alle 14 oder 21 Tage vor einem Umzug ziehen ihn nicht zurück (und es entsteht keine Reise über die Jahre am alten Ort); seltene Fotos zu Hause mit Reisen und drei Wochen Urlaub beenden ihn nicht, ein Monat woanders schon | StayStartTests.visitsBeforeTheMoveDoNotPullTheStayStartBack, sparsePhotosAtHomeKeepTheStayFromItsStart, threeWeeksAwayKeepTheStayAMonthEndsIt; ReReviewChangeAfterAMovePipelineTests.visitsBeforeTheMoveAddNoTripAfterPickingTheNewTown |
| Ohne Datum (nur Werte früherer Stände dieses Branches, und die Tests der Zeitraum-Regeln) gilt das gewählte Zuhause für jedes Datum, auch Fotos ohne Datum | HomeAtDateTests.chosenHomeHoldsForEveryDate |
| „Stimmt“ gilt ab der Bestätigung; davor entscheidet weiter die Erkennung (mit beiden Zuhause in den Monaten eines Umzugs) | HomeAtDateTests.confirmedHomeHoldsFromTheConfirmation |
| „Kein Zuhause“: kein Foto ist zu Hause, Reisen bleiben (sie richten sich weiter nach dem gewöhnlichen Aufenthaltsort) | HomeAtDateTests.noHomeHoldsForEveryDate, HomeTripTests.noHomeMeansNoPhotoIsAtHomeButTripsStay |
| Frühere Zuhause als Kette, Ende nicht eingeschlossen | HomeAtDateTests.formerHomesFormAChain |
| Überschneidung: der Zeitraum, der zuerst endet, gewinnt; gleiches Ende: der spätere Beginn | HomeAtDateTests.overlapIsDecidedForThePeriodThatEndsFirst |
| Früheres Zuhause und jetzt kein Zuhause | HomeAtDateTests.formerHomeAndNoHomeNow |
| „Stimmt“ ändert keine Reise und kein Zuhause-Foto, auch nach einem Umzug (erkannt „seit“); spätere Fotos verschieben das bestätigte Zuhause nicht mehr | HomeTripTests.confirmingTheDetectedHomeChangesNothing, confirmingAfterAMoveChangesNothing; HomeReviewCoreTests.stimmtAfterAMoveChangesNothing; HomeReviewStimmtPipelineTests.stimmtAfterAMoveAddsNoTrip |
| Warum nicht ab dem erkannten „seit“: es liegt bis zu zwei Monate vor dem Umzug, die letzten Wochen am alten Ort würden eine Reise; die Regeln in Gebrauch lassen keine | HomeReviewNaiveFixTests.confirmingFromTheDetectedSinceWouldMakeTheLastWeeksATrip |
| Reisen am Zuhause ihrer Zeit gemessen (Wochenende in München vor dem Umzug) | HomeTripTests.tripsAreJudgedAgainstTheHomeOfTheirTime, HomePipelineTests.formerHomeBringsBackTheTripBeforeTheMove |
| Eigene Orte: keine Reisen, keine Zuhause-Fotos | HomeTripTests.staysAtAPlaceOfTheUsersAreNoTrips |
| Reisename mit dem Zuhause der Reisezeit („Bayern“ nur, wenn Bayern damals nicht Zuhause war), auch über die Vorschläge (Beginn der Reise) | HomeNamingTests.tripNamesUseTheHomeOfTheTripsTime, tripSuggestionsAreNamedWithTheHomeAtTheirStart |
| Orte-Alben des Zuhauses folgen der Einstellung | HomeNamingTests.placeAlbumsOfTheHomeFollowTheSettings |
| Orte des gewählten Zuhauses aus den Fotos im Umkreis, nicht nur aus dem Namen bei der Wahl (ohne Namen oder nur Region: kein Album „Deutschland“/„München“); Land über der Grenze im Umkreis ist Zuhause, solange seine Fotos Alltag sind | HomeReviewCoreTests.chosenHomeWithoutItsTownNameKeepsTheHomeOutOfPlaceAlbums, HomeNamingTests.aCountryAcrossTheBorderInsideTheHomeIsNoAlbum |
| „Ausland“ in der Suche am Zuhause des Aufnahmetags | HomeSearchTests.abroadFollowsTheHomeOfEachDate |
| Ring zählt das gewählte Zuhause | HomePipelineTests.ringCountsTheHomeTheUserChose |
| Orte zur Auswahl aus den eigenen Fotos, durchsuchbar, offline Regionen (Mittelpunkt dort, wo die Fotos am dichtesten sind) | HomeCandidateTests (3) |
| Name des erkannten Zuhauses aus den Fotos (offline: Region) | HomeNamingTests.homeNameComesFromThePhotosNearIt |
| Speichern, Migration ohne Einstellung, ältere und neuere Stände, Neuaufbau, Sicherung | HomeSettingsStorageTests (4), HomePipelineTests.settingsAreStoredKeptByARebuildAndInTheBackup, olderStoredValueIsRead |
| Unlesbare Werte (`user.home`, `user.heldSuggestions`, unbekannte Ortsart) halten keine Analyse auf | HomeReviewStoreTests.unreadableHomeValuesDoNotStopTheAnalysis, ReReviewHomeStoreTests.damagedHomeBytesDoNotStopTheAnalysis |
| Änderung macht nur die Vorschläge neu: kein Foto gelesen, kein Ort online, kein Albumeintrag und kein Plan geändert | HomePipelineTests.resuggestReadsNoPhotoAndTouchesNoAlbum |
| Ausgewählter Vorschlag bleibt wie gewählt (auch im nächsten Lauf), bis er abgewählt ist; Hinweis zählt Weggefallenes, Neues, Gehaltenes | HomePipelineTests.chosenSuggestionIsHeldAndTheOverviewIsTold |
| Die Änderung wird mit einer Vormerkung (`analysis.pendingHomeChange`) in einer Transaktion gespeichert; wer die Vorschläge zuerst neu macht (resuggest, ein Lauf mit dem Lock, der nächste Start), hält die Auswahl und sagt es der Übersicht | HomeReviewPipelineTests.homeChangeAppliedByARunKeepsTheChosenSuggestion, HomeReviewDuringRunTests.runDuringAHomeChangeHoldsTheChoiceAndTellsTheOverview, ReReviewHomeTests.aNeinWhileTheSuggestionsAreMadeHoldsBackTheNotice |
| Vorschläge, die zwischen der Prüfung auf eine Vormerkung und dem Speichern einer neuen Änderung fertig werden, lassen die Vormerkung stehen (Prüfung, Speichern und Generation wirken wie ein Schritt); die nächsten Vorschläge wenden sie an | HomeChangeMarkTests.suggestionsFinishingWhileAChangeIsStoredKeepTheMark |
| Gehaltener Vorschlag verliert gelöschte Fotos; ohne Fotos wird er losgelassen | HomeReviewPipelineTests.heldSuggestionDropsDeletedPhotos |
| Orte des Zuhauses linear: Schlüssel einmal je Ort der Mediathek, je Zuhause nur der Abstand (50.000 Fotos, drei Zuhause: 0,03 s statt 3 s; Suchindex 0,8 s statt 4,8 s, Release) | ReReviewHomeTimingTests.homePlacesAreWorkedOutOncePerPlace |
| `rematch()` während „Analyse neu aufbauen“ schreibt keine alten Vorschläge in den frischen Speicher | ReReviewHomeTests.rematchDuringRebuildLeavesNoOldSuggestions |
| „Analyse neu aufbauen“ wartet auf eine laufende Änderung (Run-Lock) | HomeReviewStoreTests.rebuildWaitsForResuggestAndLeavesAFreshStore |
| Hin und zurück vor „OK“: kein Hinweis | HomePipelineTests.changingBackLeavesNothingToSay |
| Ohne Vorschläge wartet die Änderung auf die Analyse | HomePipelineTests.withoutSuggestionsResuggestWaitsForTheAnalysis |
| Texte (Name, Zusammenfassung, früheres Zuhause, eigene Orte, Englisch) | App: HomeTextTests (5); StringCatalogTests.countVariesByPlural (4 neue Zählungen) |

Nur syntaktisch bzw. im Simulator-Build geprüft: der Bildschirm „Dein Zuhause“, die Auswahl
der Orte und die Karte „Zuhause geändert“ (kein UI-Schritt; der UI-Lauf teilt sich den Simulator
mit den anderen Tests und wurde nicht angefasst). Ebenso in der App: während eine Änderung
läuft, startet keine Analyse (eine angefragte, auch nach einer Foto-Änderung, startet danach,
mit Bereich und „per Tipp gestartet“), kein Plan (Übernehmen ist gesperrt; Rückgängig und
Fortsetzen sagen „Gerade nicht möglich“) und kein Neuaufbau („Gerade nicht möglich“, danach
startet keine Analyse); Auswahl, „Hinzufügen“, „Ja, hier bin ich öfter“ und „Nein, das sind
Reisen“ sind gesperrt, unter der Frage steht warum (ebenso während Analyse, Anlegen und
Neuaufbau für „Ja“). Den vorgeschlagenen Tag für „Seit wann“ rechnet die App einmal beim
Antippen des Orts aus. „Stimmt“ fehlt, solange das erkannte
Zuhause keinen Namen hat. Die Frage „Seit wann wohnst du dort?“ nach „Ändern“ ist ein Blatt mit
Datumsauswahl.
