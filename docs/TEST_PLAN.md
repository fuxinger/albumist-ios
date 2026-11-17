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
| A5 App beendet beim Umsetzen | 🟡 | UndoHardening: resumeAfterTheAppEndedRightAfterCreating…, interruptedUndoIsNotTaken…; ResumeFill: planCreatedAlbumGetsItsPhotos, photoIgnoredSinceIsNotFilledIn, ignoredPhotoDoesNotTouchTheUsersAlbumOnResume, userAlbumUntouched, userAlbumUntouchedWhenTheNewAlbumWasInterrupted, secondInterruptionThenResume, secondInterruptionBeforeTheRequestThenResume, undoAfterwardsRemovesExactlyWhatAlbumistAdded, undoAfterwardsRemovesTheFilledAlbum, managedRecordKnowsTheFilledPhotos; UI test5, Gerätebedingungen test07 („Rest anlegen“: Album hat danach seine 2 Fotos) | UI test5 wird repariert (in Arbeit) |
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
| D6 Bewertungsbitte (App Store) nach einem Plan, der neue Alben vollständig und ohne Fehler angelegt hat, kurz nachdem man sein Ergebnis verlassen hat (nicht nur nach den ersten Alben): nie beim Start, nie nach Fehler, Unterbrechung oder Rückgängig, nie während Analyse, Anlegen oder Änderung am Zuhause, nie wenn man Albumist in der Wartezeit verlässt, nie mit Beispielfotos oder im UI-Test; höchstens einmal je Version und frühestens 120 Tage nach der letzten | 🟡 | ReviewPrompt (32 Tests, jede Regel einzeln): appStartNeverAsks, asksAfterAPlanWithNewAlbumsEvenOnTheFirstDay, receiptOpenedFromTheResultHoldsTheQuestionBack, undoOnTheResultMeansNoQuestion, leavingAlbumistWhileTheQuestionWaitsDropsIt, questionLongAfterLeavingTheResultIsNotAsked, neverWithTheSamplePhotosInTheLibrary, neverWithin120DaysOfTheLastQuestion | Verdrahtung in der App (`ResultCard`, `PlanReceiptView`, `MainTabs`, `AppModel.sceneChanged`) ohne eigenen UI-Schritt: UI-Tests bekommen die Frage nie; echter Dialog 📱 (in TestFlight zeigt iOS ihn nicht) |
| E1 Kaputte Datenbank | ✅ | DataSafety: garbageFile…, truncatedFile…, damagedPageIsFoundAtLaunch, rebuildSetsTheDamagedFileAside…; UI test4 | — |
| E2 Migration alter Versionen | ✅ | DataSafety: everyOlderVersionMigratesWithItsDataIntact, migrationThatFailsHalfWayLeavesTheOldVersion | — |
| E3 Sicherung wiederherstellen | ✅ | UI test4, Store: backup…, DataSafety: emptyDatabaseNeverOverwritesAFullCopy, libraryStateOfTheCopyFollowsThePhotoAccess; DatabaseIdentityTests: newPhoneGetsTheDecisionsBackAndTheCopySurvives | — |
| E4 Zurücksetzen | ✅ | DataSafety: resetClearsTheAnalysisAndNothingElse, resetIncludingDecisionsLeavesNoJournalBehind | — |
| F1 Jede Wahl beim Einstieg | 🟡 | UI test1 | Varianten (in Arbeit) |
| F2 Jeder Bildschirm hin und zurück | 🟡 | UI test3 | tiefer, ohne Auslassliste (in Arbeit) |
| F3 Suche mit echten Anfragen | 🟡 | SearchQuerySet: 100 echte Anfragen (alle 100 finden, was sie sollen); SearchPerformance: 50.000 Fotos; SortlySearchUITests: 6 Anfragen in der UI | erster UI-Lauf steht aus |
| F4 Probejahr bleibt | 🟡 | trialYearIsKeptForLaterRuns, UI test6 | Neustart, Wahl im Onboarding |
| F5 Foto groß ansehen | 🟡 | UI test1 | Zoom |
| F6 Sortiert-Ring mit eigenen Alben (Gerätetest 15.11.: 811, dann 157) | 🟡 | SortedCount: eigene Reisealben zählen für ihr Land, Zuhause zählt nicht für Länder und Orte, Neuaufbau, zweiter Lauf, Übernehmen und Rückgängig, „Nicht jetzt“ und „Albumists Fotos herausnehmen“, leere Mediathek, eingeschränkter Zugriff, 100.000 Fotos, alter Stand lädt, mehrere gleich gut passende Alben zählen alle, neue Fotos nach einer Reise bleiben unsortiert im Ring | Ring-Text und Diagnosezeile nur syntaxgeprüft; Zahl auf dem iPhone 📱 |
| G1 Zweitwohnsitz, Pendeln, Ferienwohnung, lange Reise | 🟡 | RecurringPlace-Lebenslagen (18 Muster: Pendeln, Wochenendhaus, Ferienwohnung, Familie, Umzug, Semester, 6-Monats-Reise, Dienstreisen, Nomaden), TripTimeZone (11), RecurringPlacePipeline | UI-Frage „Bist du hier öfter?“ im UI-Lauf |
| G2 Zuhause bestätigen, ändern, „Kein Zuhause“ | 🟡 | HomeAtDate: nothingSetLeavesEveryDateToTheDetection, chosenHomeHoldsForEveryDate, confirmedHomeHoldsFromTheConfirmation, noHomeHoldsForEveryDate; HomeTrip: confirmingTheDetectedHomeChangesNothing, confirmingAfterAMoveChangesNothing, noHomeMeansNoPhotoIsAtHomeButTripsStay, chosenHomeWinsOverTheDetection; HomeNaming: placeAlbumsOfTheHomeFollowTheSettings, aCountryAcrossTheBorderInsideTheHomeIsNoAlbum; Review: stimmtAfterAMoveChangesNothing, stimmtAfterAMoveAddsNoTrip, confirmingFromTheDetectedSinceWouldMakeTheLastWeeksATrip, chosenHomeWithoutItsTownNameKeepsTheHomeOutOfPlaceAlbums; Re-Review („Ändern“ nach einem Umzug): pickingTheNewTownUnderAendernKeepsThePastAsItWas, confirmedEarlierThenPickedTheNewTownKeepsTheConfirmedYears, theStayStartsAfterTheLastLongStretchElsewhere, pickingTheNewTownAddsNoTrip, homePlacesAreWorkedOutOncePerPlace; Runden 3 und 4 (Beginn des Aufenthalts): visitsBeforeTheMoveDoNotPullTheStayStartBack (alle 14 und 21 Tage), weekendVisitsEveryWeekBeforeTheMoveDoNotPullTheStayStartBack, aShortTripAfterTheMoveKeepsTheDateOfTheMove, aWeekAbroadEachMonthKeepsTheStay, aLongHolidayEndsTheProposedStayButChangesNoTrip, sparsePhotosAtHomeWithTripsChangeNoTrip, fewPhotosMostlyOnTripsPutNoHomePhotoOnATrip, movingTwiceOrBackStartsTheStayAtTheLastMove, withFewerThan28PhotoDaysTheStayStartsOnTheFirstDayThere, visitsBeforeTheMoveAddNoTripAfterPickingTheNewTown; HomePipeline: ringCountsTheHomeTheUserChose; HomeSearch: abroadFollowsTheHomeOfEachDate; App: HomeTextTests | Bildschirm „Dein Zuhause“ im UI-Lauf |
| G3 Umzug: früheres Zuhause mit Zeitraum, Überschneidungen | 🟡 | HomeAtDate: formerHomesFormAChain, overlapIsDecidedForThePeriodThatEndsFirst, formerHomeAndNoHomeNow; HomeTrip: tripsAreJudgedAgainstTheHomeOfTheirTime; HomeNaming: tripNamesUseTheHomeOfTheTripsTime, tripSuggestionsAreNamedWithTheHomeAtTheirStart; HomeCandidate: aRegionIsPlacedWhereItsPhotosAreDensest; HomePipeline: formerHomeBringsBackTheTripBeforeTheMove | UI-Lauf |
| G4 Eigene Orte („Eltern“, „Arbeit“, eigener Name) sind keine Reisen | 🟡 | HomeTrip: staysAtAPlaceOfTheUsersAreNoTrips; HomeSettingsStorage: personalPlaceKeepsItsIdAndTakesTheUsersName; HomePipeline: chosenSuggestionIsHeldAndTheOverviewIsTold | UI-Lauf |
| G5 Änderung am Zuhause macht nur die Vorschläge neu: keine Bildanalyse, kein Album, Auswahl bleibt, Übersicht sagt, was wegfiel – auch wenn ein Lauf, ein Neustart oder ein Fehler dazwischenkommt | 🟡 | HomePipeline: resuggestReadsNoPhotoAndTouchesNoAlbum, chosenSuggestionIsHeldAndTheOverviewIsTold, changingBackLeavesNothingToSay, withoutSuggestionsResuggestWaitsForTheAnalysis; Review: homeChangeAppliedByARunKeepsTheChosenSuggestion, runDuringAHomeChangeHoldsTheChoiceAndTellsTheOverview, ReReviewHomeTests.aNeinWhileTheSuggestionsAreMadeHoldsBackTheNotice, heldSuggestionDropsDeletedPhotos, rebuildWaitsForResuggestAndLeavesAFreshStore, ReReviewHomeTests.rematchDuringRebuildLeavesNoOldSuggestions, HomeChangeMarkTests.suggestionsFinishingWhileAChangeIsStoredKeepTheMark | Karte „Zuhause geändert“ im UI-Lauf |
| G6 Zuhause-Einstellungen gespeichert, alte Stände lesbar, übersteht „Analyse neu aufbauen“ und Sicherung | ✅ | HomeSettingsStorage: roundTrip, olderAndNewerValuesStayReadable, olderPlaceAnswersStayReadable; HomePipeline: settingsAreStoredKeptByARebuildAndInTheBackup, olderStoredValueIsRead; Review: unreadableHomeValuesDoNotStopTheAnalysis, ReReviewHomeStoreTests.damagedHomeBytesDoNotStopTheAnalysis | — |
| G7 „Themen“ oder „Dokumente“ erst später eingeschaltet: ältere Fotos bekommen ihre Bildlabels im nächsten Lauf (nur die Labels, kein zweiter voller Blick, kein Text erneut gelesen), Zahl geht nie zurück, Pause wirkt, Aus/An ändert nichts, Lesefehler werden gezählt und gestaffelt (das frühere Ergebnis bleibt Byte für Byte), beide Bereiche sehen nie fertig aus, solange Labels fehlen, alte Datenbanken; die Änderung in den Einstellungen startet den Lauf (während eines Laufs genau einer danach, eine Pause bleibt), das Nachholen zählt nicht als „neue Fotos“, eine Phase, die vor allem aus ihm besteht, hat eigene Worte (P32) | 🟡 | LabelsLater: turnedOnLaterTheOlderPhotosGetLabelsOnlyOnce, offAndOnAgainKeepsTheLabelsAndDoesNothing, documentsOnLaterReadsOnlyTheNewDocuments, pausedWhileAddingLabelsGoesOnWhereItStopped, unreadablePhotosAreNotTriedEveryRun, labelsOnlyFailuresAreCountedAndKeepTheEarlierResult, labelsOnlyFailureThenReadable, themenAndDokumenteArePendingWhileLabelsAreMissing, settingsChangesThatNeedARun, anEditedImageNeedsItsLabelsAgain, migrationMarksOnlyPhotosWithLabels; LabelsLaterFollowUp: aSettingsChangeStartsTheRunItNeeds, updateReturnsTheSettingsItReplaces, turnedOnDuringARunTheRunAfterItGivesTheLabels, storeCountsThePhotosThatOnlyNeedTheirLabels | App: Lauf nach der Änderung in `AppModel.saveSettings` (`runAfterSettingsChange`), `labelledAssets` im abgekoppelten Task von `refreshDerived` an `DerivedLibraryStatus.derive` (noch nicht auf einem Mac gebaut); Einschalten in den Einstellungen startet den Lauf 📱 |

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
| P6 Akku unter 10 % (und Hitze: „Wartet …“ bleibt stehen, auch wenn die letzte Meldung davor erst nach Beginn des Wartens gelesen wird, UI-Lauf 43930271358) | DeviceStateTests: slowerReason…; AnalysisDisplayTests: cardStates, mailboxKeepsAWaitThatBeganAfterTheLastReport | DeviceConditionUITests test01, test02 |
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
| P23 (Stresslauf 43833158673, Reviews von d612bc0 und 9f0bc40) Fortsetzen: die Zahl geht nie zurück und bewegt sich mit der Arbeit, auch nach neuen oder gelöschten Fotos, mehr Arbeit bei gleicher Zahl (neue Analyseversion) und abgebrochenem erstem Lesen; Breiten nur einmal neu verteilt; Pause beim Aufholen zeigt den Wert, von dem es weiterging; der Stand gehört zu seiner Datenbank (neue oder leer wiederhergestellte Datenbank ignoriert alten Stand); neue Breiten aus der Arbeitsmenge ziehen den Balken nie zurück | AnalysisDisplayTests: resumedAnalysisNeverGoesBackAndMovesOn, resumedTwiceStillNeverGoesBack, pausedWhileCatchingUpKeepsTheValue, markerBelongsToItsDatabase, moreWorkGoesOnFromTheFloor (3 Fälle), backOnceAndTheRealValueWhenAhead; ReviewSwitchesEvidenceTests; ReviewSecondPassEvidenceTests; DatabaseIdentityTests; FullRunDisplay: Invariante 3 (gezeichneter Wert fällt nie) | Stempel der Datenbank im Stand, Prüfung beim Start (AppModel, nur Syntax) |
| P24 (Stresslauf, Review) Nichts steht still beim Lesen der Mediathek und beim Kartendurchgang der Orte; Pause wirkt dort beim nächsten Teil, nichts Halbes wird gespeichert | PipelineTests: readingTheLibraryIsCountedAsItGoes, pauseStopsTheLibraryRead, pausedReadKeepsWhatItRead; PlaceResolutionTests: manyOfflinePlacesAreSavedAndCountedInParts, pauseStopsTheMapPassAtTheNextPart, checkedCountGoesOnAfterAPause; ReviewPlacesEvidenceTests: countMovesDuringTheMapPassAtTownLevel | „… mit der Karte geprüft“ auf der Karte, PhotoKit liest in 250er-Schritten 📱 |
| P25 (Review) Orte: jeder Ort einmal gezählt, eine Stadt wird nie durch ein Land ersetzt | ReviewPlacesEvidenceTests: eachPlaceCountedOnceAtTownLevel; PlaceResolutionTests: refinementNeverSavesACountryOverATown | — |
| P26 (Review) Übersicht: alles, was mit der Mediathek wächst, außerhalb des Haupt-Threads; frühe Vorschläge in großen Mediatheken seltener nachgesehen | DerivedLibraryStatusTests: sameAsBefore, olderRefreshFinishingLastDoesNotWin, earlyLookIsRarerInALargeLibrary; LoadTests: „derived (off main)“ | Stresslauf: Haupt-Thread-Stockungen um den Pause-Tipp (UITEST_MAIN_BLOCKED) |
| P27 (Review von 83db832, 1) Der Stempel der Datenbank gehört nicht zur Sicherungskopie: neue Datenbank mit eigenem Stempel bekommt die Entscheidungen zurück, eine Kopie einer leeren Datenbank ist leer und ersetzt keine volle, Wiederherstellen und „Analyse neu aufbauen“ behalten den eigenen Stempel | ReviewIdentityEvidenceTests: freshDatabaseWithItsStampStillGetsTheDecisionsBack, copyOfAnEmptyDatabaseIsEmpty, restoreKeepsTheNewStamp; DatabaseIdentityTests: newPhoneGetsTheDecisionsBackAndTheCopySurvives (ganzer Ablauf wie AppModel.load), resetKeepsTheStamp | Neues iPhone aus Geräte-Backup 📱 |
| P28 (Review von 83db832, 2 und 3) Fortsetzen mit neuer Arbeit: der Stand merkt sich die übrige Arbeit (Fotos und Screenshots); ist beim Zurückkommen viel mehr da (mehr als 1,5-mal und mindestens 500 mehr, so wie die Arbeitsmenge zählt: nur der gewählte Teil der Mediathek und nur, was die Analyse ansieht), beginnt ein eigener Abschnitt mit ehrlicher Zahl ab seinem Anfang: „Neue Fotos werden analysiert“ oder „Analyse nach Update“; die Beschriftung erscheint erst zusammen mit dem eigenen Abschnitt, nie vorab (Review von 0305d20). Nie 100 % vor dem Ende (höchstens 99 %, auch VoiceOver, Details, Sperrbildschirm). | ReviewThirdPassEvidenceTests: newWorkBeforeTheStoppedStepIsNotFrozenAtTheFloor, neverReads100WhileWorkIsLeft; AnalysisDisplayTests: muchMoreWorkHasAClearThreshold, markerKeepsTheWorkLeft, newPhotosStartTheirOwnPhase, updateStartsItsOwnPhase, newPhotosOutsideTheScopeStartNoPhase, newItemsTheAnalysisDoesNotLookAtStartNoPhase, aPhaseKeepsItsLabelWhenItGoesOn, neverReads100BeforeTheEnd; FullRunDisplay: manyNewPhotosStartTheirOwnPhase, anUpdateStartsItsOwnPhase | Beschriftung auf der Karte, Stand mit übriger Arbeit (AppModel, nur Syntax); Stresslauf: 50.000 neue Fotos zeigen „Neue Fotos werden analysiert“ 📱 |
| P29 (Reviews von 11ef3e1 und 0305d20) Fortsetzen ohne viel neue Arbeit: der Wert fällt nie unter den Stand von damals und bewegt sich ab dort mit der Zeit, die der Lauf arbeitet, als Anteil an der geschätzten Restzeit (Zahl und Balken stehen nie länger als 10 s, auch beim Nachzählen, bei neuen Fotos vor dem Halteschritt und nach gelöschten Fotos); der echte Wert übernimmt, sobald er vorn liegt; nichts wird neu verteilt, schon getane Arbeit zählt nie doppelt (zurück an der Stelle des Anhaltens kaum über dem Stand). Der Stand behält bis dahin die Stelle des Anhaltens. Der Reisen-Schritt zählt gruppierte Fotos. 100 % nur nach einem vollständigen eigenen Lauf; eine abgebrochene Nachbearbeitung im Hintergrund nimmt einer fertigen Analyse die 100 % nicht; nach einem vollständigen Lauf zeigen die Details alle Schritte erledigt | ReviewFourthPassEvidenceTests (2); ResumedRunNeverStandsStillTests: earlyLabelThenTheNumberFallsUnderIt, heldNumberStandsStillThroughNewWork, deletedPhotosHoldTheNumber, tripsStepGapsAtFiftyThousand; AnalysisDisplayTests: moreWorkGoesOnFromTheFloor (3 Fälle), backOnceAndTheRealValueWhenAhead, backWhereItStoppedReadsAboutTheFloor, newOrDeletedPhotosBeforeTheStopDoNotHoldTheValue, olderMarkerIsBackAtItsStage, onlyTheLastRunsOwnOutcomeIsComplete; AnalysisCoverageTests: tripsStepCountsThePhotosItGroups; FullRunDisplay: Invariante 8 (Zahl oder Balken bewegen sich alle 10 s, die Zählung allein reicht nicht), Invariante 10, Invariante 3 (Zahl fällt nur mit neuer Überschrift), resumeIsHeldUntilWhereItStopped, fewNewPhotosAreHeldThenGoOn, patternsSayWhenTheyBegin | Zeitanteil im Tick, Stand mit Position und Restzeit, Details nach vollständigem Lauf (AppModel, nur Syntax) 📱 |
| P30 (Review von c772325) Fortsetzen nahe am Ende und über Abbrüche: neue Arbeit, durch die sich die Zahl von ihrem Stand bis 99 % nur langsamer als 0,25 % je 10 s bewegen könnte (`ResumedRun.visiblePace`), beginnt einen eigenen Abschnitt, auch unter 500 Fotos; ein Abschnitt, dessen Überschrift schon steht, beginnt nie unter derselben Überschrift neu (viel mehr Arbeit allein: weiter ab seinem Wert; nur wenn die Zahl sich nicht sichtbar bewegen könnte: „Weitere neue Fotos werden analysiert“). Abbrüche beim erneuten Lesen der Mediathek: der Stand merkt sich, wie lange schon gelesen wurde (`caughtUp`); ein Lauf, der dasselbe noch einmal liest, bewegt sich nur im sichtbaren Mindesttempo (Grenze: n Abbrüche zu a s bewegen höchstens den Zeitanteil eines Laufs plus (n − 1) · a · 0,025 % je s; 10 × 40 s ab 37 % bei 1.000 s Rest: höchstens 48,4 % statt 57 %). Ein Stand ohne Restzeit (ältere Version) bewegt sich binnen 10 s: übrige Arbeit oder Fotos der Mediathek mal übliche Zeit je Foto. Eine vollständige Nachbearbeitung löscht den Stand des unfertigen Laufs (kein „Macht da weiter · 37 %“ nach 100 %). Gemessen auf ganzen Prozent und am Balken (0,2 %), mit allen Invarianten der simulierten Karte | FloorTimeShareTests: newPhotosAfterAStopAtTheEndStartTheirOwnPhase, highFloorWithNewWorkMovesInAPhaseOfItsOwn, morePhotosGoOnUnderTheTitleAlreadyShown, morePhotosAtTheEndOfAPhaseStartOneUnderAnotherTitle, cutOffsWhileReReadingAddOneRunsTimeShare, fewNewPhotosMoveTheNumberOnWholePercent; AnalysisDisplayTests: newWorkTooSlowToShowStartsAPhase, aShownPhaseStartsAgainOnlyUnderAnotherTitle, olderMarkerWithoutTimeLeftMovesWithinTenSeconds, onlyTheLastRunsOwnOutcomeIsComplete; ResumedRunNeverStandsStillTests: heldNumberStandsStillThroughNewWork, deletedPhotosHoldTheNumber (ganze Prozent, Balken, `finish`) | Restzeit an den Abschnitt, `caughtUp` im Stand, Stand nach vollständiger Nachbearbeitung gelöscht (AppModel, nur Syntax) 📱 |
| P31 (Review von ee36188) Die Tempo-Regel gilt nur nahe am Ende: ein eigener Abschnitt beginnt nur bei neuer Arbeit, höchstens 5 Prozentpunkten Platz bis 99 % (`ResumedRun.nearCapRoom`) und weniger als 0,25 % je 10 s; ein neues Foto in einer großen Mediathek (50.000 Fotos, 37 %) startet nichts, die Zahl geht im ehrlichen Tempo der Arbeit weiter (auf langen Läufen darf ein ganzes Prozent länger als 10 s dauern, nie länger als das ehrliche Tempo, die Zählung bewegt sich). Ein Update ohne zusätzliche Arbeit startet keinen Abschnitt. Update nach Update nahe am Ende: „Analyse nach erneutem Update“, abwechselnd mit „Analyse nach Update“. Restzeit: der Orte-Schritt zählt nur Fotos ohne aufgelösten Ort; ältere Stände ohne Restzeit rechnen jeden Schritt mit seiner üblichen Zeit (Text 0,5 s je Screenshot) | NearCapPhaseRuleTests: oneNewPhotoDoesNotRestartALongAnalysis, anUpdateWithoutNewWorkStartsNoPhase, updateAfterUpdateNearTheCapStartsUnderAnotherTitle; AnalysisDisplayTests: aShownPhaseStartsAgainOnlyUnderAnotherTitle, olderMarkerWithoutTimeLeftMovesWithinTenSeconds; AnalysisCoverageTests: placesLeftCountsOnlyUnresolvedPlaces | Überschrift „Analyse nach erneutem Update“ auf der Karte 📱 |
| P32 (Zweitprüfung Labels-Fix, M2) „Themen“ oder „Dokumente“ eingeschaltet, dann fortgesetzt: ist die neue Arbeit vor allem Labels für schon analysierte Fotos (`AnalysisWorkload.labelsLeft` mindestens so groß wie der Rest des Hinzugekommenen), heißt der eigene Abschnitt „Fotos werden für die neuen Bereiche angesehen“ statt „Neue Fotos werden analysiert“ oder „Weitere neue Fotos werden analysiert“; nach einem Update bleibt „Analyse nach Update“. Ob ein Abschnitt beginnt, seine Zahl und die Breiten hängen nicht von der Überschrift ab; eine gezeigte Überschrift kommt nie gleich noch einmal. Prüflauf: „Beim Prüfen N Fotos für die neuen Bereiche angesehen.“, neue Fotos ohne die, die nur Labels bekamen | LabelsLaterFollowUpTests: workloadAndReportSayTheLabelsApartFromNewPhotos, labelsForAreasTurnedOnAreNamedForTheNewAreas, aPhaseShownBeforeGoesOnUnderTheRightTitle, theLabelChangesNeitherThePhaseNorItsNumber (1.944 Fälle), firstAnalysisPausedThenThemenOnIsNamedForTheNewAreas (1.500 Fotos, ganze Läufe); StringCatalogTests: Plural der neuen Übersichtszeile | Überschrift auf der Karte, Zeile in der Übersicht (noch nicht auf einem Mac gebaut) 📱 |

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
| Beginn des Aufenthalts: nur Tage mit Fotos zählen; er endet an 28 Fototagen, von denen mehr als die Hälfte woanders sind, und beginnt am Tag mit dem größten Vorsprung der Tage dort (ein Tag woanders zählt doppelt). Besuche alle 14 oder 21 Tage und jedes Wochenende vor einem Umzug ziehen ihn nicht zurück (keine Reise über die Jahre am alten Ort), eine kurze Reise nach dem Umzug schiebt ihn nicht dahinter, eine Woche im Ausland jeden Monat beendet ihn nicht; drei oder sechs Wochen Urlaub und seltene Fotos zu Hause mit Reisen beenden ihn, ohne eine Reise zu ändern; zweimal umgezogen, zurückgezogen, weniger als 28 Fototage | StayStartTests.visitsBeforeTheMoveDoNotPullTheStayStartBack, weekendVisitsEveryWeekBeforeTheMoveDoNotPullTheStayStartBack, aShortTripAfterTheMoveKeepsTheDateOfTheMove, aWeekAbroadEachMonthKeepsTheStay, aLongHolidayEndsTheProposedStayButChangesNoTrip, sparsePhotosAtHomeWithTripsChangeNoTrip, fewPhotosMostlyOnTripsPutNoHomePhotoOnATrip, movingTwiceOrBackStartsTheStayAtTheLastMove, withFewerThan28PhotoDaysTheStayStartsOnTheFirstDayThere; ReReviewChangeAfterAMovePipelineTests.visitsBeforeTheMoveAddNoTripAfterPickingTheNewTown |
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
Neuaufbau für „Ja“, und unter „Keine Reise, hier bin ich öfter“ auf einer Reise). Den vorgeschlagenen Tag für „Seit wann“ rechnet die App einmal beim
Antippen des Orts aus. „Stimmt“ fehlt, solange das erkannte
Zuhause keinen Namen hat. Die Frage „Seit wann wohnst du dort?“ nach „Ändern“ ist ein Blatt mit
Datumsauswahl.
