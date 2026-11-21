import Foundation
import AlbumistCore

/// What the overview's first card says about the sorted count (`OverviewView.statusCard`), as
/// pure values: the app only renders them (review P3-03 of 18.11.2026).
///
/// Every number on it agrees with the analysis card below it ("Alle 246 Fotos analysiert"): the
/// ring's total and the groups it leaves out (`NotCounted`) add up to those photos, each photo
/// in exactly one of them. Before, "82 von 176 sortiert" and "Außerdem nicht mitgezählt: 57 Fotos
/// von zu Hause" stood next to "Alle 246 Fotos analysiert", and the 13 photos without a place
/// were said nowhere.
///
/// It never says "0 von 0 sortiert" (the review saw it while the analysis ran again after the
/// decisions came back from the backup), and never a ring that cannot mean anything yet:
/// - `counting` ("Wird gezählt", with a spinner): the analysis has not gone through, and no
///   suggestion exists in this library yet or no photo was read yet, while the analysis runs.
///   Without suggestions no photo can count as sorted (an own album counts through the suggestion
///   it fits, an album of Albumist through the suggestion it was made for), so the ring could
///   only say "0 von 0" or "0 von 246". This is the first start, the time after the decisions
///   came back from the backup, and "Analyse neu aufbauen" when no count was on screen to hold.
///   It ends with the first suggestions (the early set of trips and places, minutes into a first
///   run) or when the analysis went through.
/// - `notCountedYet` ("Noch nicht gezählt", no spinner): the same, while the analysis does not
///   run: paused by the user, waiting for the device or for Photos, ended early (also across
///   launches until it goes on). A spinner then turned for as long as the pause lasted, right
///   above the paused analysis card (second review of P3-03).
/// - `recounting` ("Wird neu gezählt", with a spinner): a count held while it is made anew
///   (`RecountState`), as before, while the analysis works.
/// - `recountWaiting` ("Zuletzt 82 von 176 sortiert", no spinner): the same held count while the
///   analysis does not work. The hold ends only with new suggestions or a run that went through
///   (`RecountState.next`), so a Pause kept the spinner turning for as long as it lasted.
/// - `noMainAreaChosen`: no main area counts (none chosen in the settings, or the chosen ones
///   turned off, which the start allows): every photo stayed open for good ("0 von 300"). The
///   count behind it has no photo in the ring then (`Progress.total` 0): each is outside the main
///   areas, ignored or excluded, and the library's lists, the search and the photo info say the
///   same, never "Nicht sortiert" (finding N-01).
/// - `nothingToSort` ("Nichts zu sortieren"): counted, and every photo is left out, for example
///   every photo the ring would count is ignored (question to Fuchs, 18.11.: text or "0 von 0").
/// - `ring`: "82 von 176 sortiert".
public enum SortedCountCard: Equatable, Sendable {
    case counting
    case notCountedYet
    case recounting(RecountState)
    case recountWaiting(RecountState)
    case noMainAreaChosen
    case nothingToSort(NotCounted)
    case ring(Ring)

    public struct Ring: Equatable, Sendable {
        public var fully: Int
        public var total: Int
        public var partially: Int
        public var notCounted: NotCounted

        public init(fully: Int, total: Int, partially: Int, notCounted: NotCounted) {
            self.fully = fully
            self.total = total
            self.partially = partially
            self.notCounted = notCounted
        }

        /// The ring's share (`ProgressRing` shows it through `Progress.shownShare`).
        public var fraction: Double { total == 0 ? 0 : Double(fully) / Double(total) }
    }

    /// The photos the ring leaves out, each in one group: "Außerdem nicht mitgezählt: 57 Fotos von
    /// zu Hause, 13 Fotos ohne Ort, 3 ignorierte Fotos und 6 Fotos, für die sich kein eigenes Album
    /// lohnt." With the ring's total they are every photo of the analysis card
    /// (`DerivedLibraryStatus.photos` = `Progress.allPhotos`).
    public struct NotCounted: Equatable, Sendable {
        /// Taken at home (`LibraryStatus.NotCounted.home`).
        public var home: Int
        /// No album on purpose: too few photos, a routine visit (`LibraryStatus.NotCounted.noAlbum`).
        public var noAlbum: Int
        /// No main area fits them for another reason: no place, a screenshot (with "Reisen" as the
        /// only main area also a photo from home). Never said before P3-03.
        public var noMainArea: Int
        /// Ignored by the user (decision Fuchs 18.11.: neither sorted nor open).
        public var ignored: Int
        /// Excluded from the analysis (`excludeFromAnalysis`, no switch in the app today): said
        /// only when there are some, so the numbers add up also then.
        public var excluded: Int
        /// "Länder und Orte" counts, so `noMainArea` are photos without a place ("13 Fotos ohne
        /// Ort"): a photo with a place counts for it unless it was taken at home or has no album
        /// on purpose (the groups above). Left are photos without a usable location, screenshots
        /// (iOS saves none with them) and the rare place without a country (open sea). Else
        /// "13 Fotos außerhalb deiner Hauptbereiche".
        public var noMainAreaIsNoPlace: Bool

        public init(home: Int = 0, noAlbum: Int = 0, noMainArea: Int = 0, ignored: Int = 0, excluded: Int = 0,
                    noMainAreaIsNoPlace: Bool = true) {
            self.home = home
            self.noAlbum = noAlbum
            self.noMainArea = noMainArea
            self.ignored = ignored
            self.excluded = excluded
            self.noMainAreaIsNoPlace = noMainAreaIsNoPlace
        }

        /// From one derived status (`DerivedLibraryStatus`): `progress` and `leftOut` are counted
        /// over the same photos. `LibraryStatus.leftOut` takes only photos outside the main
        /// areas, so `home + noAlbum` never exceeds `outsideMainAreas`; the rest has no reason of
        /// its own.
        public init(progress: OrganizationStatusResolver.Progress, leftOut: LibraryStatus.LeftOut,
                    countedAreas: Set<OrganizationArea>) {
            self.init(home: leftOut.home, noAlbum: leftOut.noAlbum,
                      noMainArea: max(0, progress.outsideMainAreas - leftOut.home - leftOut.noAlbum),
                      ignored: progress.ignored, excluded: progress.excluded,
                      noMainAreaIsNoPlace: countedAreas.contains(.places))
        }

        /// Every photo the ring leaves out.
        public var sum: Int { home + noAlbum + noMainArea + ignored + excluded }
        public var isEmpty: Bool { sum == 0 }

        /// One group as the overview names it.
        public enum Group: Equatable, Sendable {
            /// "57 Fotos von zu Hause"
            case home(Int)
            /// "13 Fotos ohne Ort" (`isNoPlace`), else "13 Fotos außerhalb deiner Hauptbereiche".
            case noMainArea(Int, isNoPlace: Bool)
            /// "3 ignorierte Fotos" ("aus 2026" with a trial year)
            case ignored(Int)
            /// "1 ausgeschlossenes Foto"
            case excluded(Int)
            /// "6 Fotos, für die sich kein eigenes Album lohnt": the one group said with a
            /// relative clause, so it comes last, where the period closes the clause. Before
            /// "und" it stayed open ("…, 6 Fotos, für die sich kein eigenes Album lohnt und 13
            /// Fotos ohne Ort.", second review of P3-03).
            case noAlbum(Int)

            /// The group's photos.
            public var count: Int {
                switch self {
                case .home(let n), .noMainArea(let n, _), .ignored(let n), .excluded(let n), .noAlbum(let n): n
                }
            }
        }

        /// The groups with photos, in the order the overview names them ("Außerdem nicht
        /// mitgezählt: …"): the group with a relative clause last.
        public var groups: [Group] {
            [.home(home), .noMainArea(noMainArea, isNoPlace: noMainAreaIsNoPlace), .ignored(ignored), .excluded(excluded),
             .noAlbum(noAlbum)].filter { $0.count > 0 }
        }
    }

    public struct Input: Sendable {
        /// The ring's count and `leftOut` from the same derived status (`AppModel.progress`,
        /// `AppModel.leftOut`).
        public var progress: OrganizationStatusResolver.Progress
        public var leftOut: LibraryStatus.LeftOut
        /// The count held while it is made anew (`AppModel.recount`).
        public var recount: RecountState?
        public var settings: OrganizationSettings
        /// Suggestions exist in this library (`AppModel.proposals` is not empty, also with the
        /// early set of a first run). An early set without any suggestion makes no count either.
        public var hasSuggestions: Bool
        /// The same three facts as `EmptyLibraryState.Input`: the analysis went through when it
        /// neither runs nor is paused and went through the library once.
        public var analysisRunning: Bool
        public var analysisPaused: Bool
        public var analysedOnce: Bool
        /// What the analysis card below shows (`AppModel.analysisCard`): "Wird gezählt" turns only
        /// while it shows the analysis working (`analysisWorks`). `nil` while it runs: not drawn yet.
        public var analysisCard: AnalysisCardState?

        public init(progress: OrganizationStatusResolver.Progress, leftOut: LibraryStatus.LeftOut = LibraryStatus.LeftOut(),
                    recount: RecountState? = nil, settings: OrganizationSettings, hasSuggestions: Bool,
                    analysisRunning: Bool, analysisPaused: Bool = false, analysedOnce: Bool,
                    analysisCard: AnalysisCardState? = nil) {
            self.progress = progress
            self.leftOut = leftOut
            self.recount = recount
            self.settings = settings
            self.hasSuggestions = hasSuggestions
            self.analysisRunning = analysisRunning
            self.analysisPaused = analysisPaused
            self.analysedOnce = analysedOnce
            self.analysisCard = analysisCard
        }

        /// The analysis works right now: it runs, and its card neither waits (for the device to
        /// cool or charge, for Photos) nor pauses. Only then does the first card show a spinner
        /// ("Wird gezählt", "Wird neu gezählt").
        public var analysisWorks: Bool {
            guard analysisRunning else { return false }
            switch analysisCard {
            case .waiting?, .pausing?, .paused?: return false
            case .running?, .quickCheck?, .finished?, nil: return true
            }
        }
    }

    public static func make(_ input: Input) -> SortedCountCard {
        let counted = countedAreas(input.settings)
        // Nothing can ever be sorted: no ring that stays at 0 % and no count to hold. First, so
        // its empty ring (finding N-01) never reads as "Nichts zu sortieren".
        if counted.isEmpty { return .noMainAreaChosen }
        // A spinner only while the analysis works, for a held count too.
        if let held = input.recount { return input.analysisWorks ? .recounting(held) : .recountWaiting(held) }
        let p = input.progress
        let wentThrough = !input.analysisRunning && !input.analysisPaused && input.analysedOnce
        // Once the analysis went through, a library without photos or suggestions has the card
        // of `EmptyLibraryState` instead; what is left here is a real count (or none to make).
        if !wentThrough && (!input.hasSuggestions || p.allPhotos == 0) {
            return input.analysisWorks ? .counting : .notCountedYet
        }
        let notCounted = NotCounted(progress: p, leftOut: input.leftOut, countedAreas: counted)
        if p.total == 0 { return .nothingToSort(notCounted) }
        return .ring(Ring(fully: p.fully, total: p.total, partially: p.partially, notCounted: notCounted))
    }

    /// The main areas the ring counts: chosen ("Zählt als sortiert") and turned on. A main area
    /// that is off counts nothing (`RecountState.waitsForLabels` reads it the same way); the start
    /// can turn "Länder und Orte" and "Reisen" off while they stay chosen. The overview's sentence
    /// "Gezählt werden nur Fotos, die zu deinen Hauptbereichen passen: …" names these.
    public static func countedAreas(_ settings: OrganizationSettings) -> Set<OrganizationArea> {
        settings.primaryAreas.intersection(settings.enabledAreas)
    }
}

// MARK: The library's lists and the photo info when no main area counts

extension SortedCountCard {
    /// What an empty list of the library tab says (`LibraryView.emptyTitle`, `emptyDescription`).
    /// With no main area counted, "Nicht sortiert" and "Sortiert" are empty because nothing can
    /// be sorted (finding N-01): they say what the overview says ("Kein Bereich zählt als
    /// sortiert", "Wähle in den Einstellungen unter „Zählt als sortiert“, welche Bereiche
    /// zählen."), not "Alles sortiert".
    public enum EmptyList: Equatable, Sendable {
        /// "Kein Bereich zählt als sortiert" with the hint to the settings.
        case noMainAreaChosen
        /// "Alles sortiert": "Alle Fotos liegen in deinen Hauptbereichen." (with "Nur 2026"
        /// "Alle Fotos aus 2026 …").
        case allSorted
        /// "Keine Fotos" with the list's own line.
        case noPhotos

        public static func make(_ bucket: InboxBucket, settings: OrganizationSettings) -> EmptyList {
            let noneCounts = SortedCountCard.countedAreas(settings).isEmpty
            switch bucket {
            case .unorganized, .organized: return noneCounts ? .noMainAreaChosen : bucket == .unorganized ? .allSorted : .noPhotos
            default: return .noPhotos
            }
        }
    }

    /// The photo info gives the hint to the settings as its "why" ("Wähle in den Einstellungen
    /// unter „Zählt als sortiert“, welche Bereiche zählen."): no main area counts, so the ring
    /// does not count the photo ("Nicht mitgezählt"), and the user did not ignore or exclude it
    /// (those say so themselves). Finding N-01.
    public static func photoInfoNamesNoMainArea(_ state: AssetOrganizationState, settings: OrganizationSettings) -> Bool {
        countedAreas(settings).isEmpty && !OrganizationStatusResolver.isIgnored(state)
            && !OrganizationStatusResolver.isExcluded(state)
    }
}

// MARK: The ring's second line (overview draft B, start page "Vorschläge")

extension SortedCountCard {
    /// What the ring counts, said under "495 von 3.114" (overview draft B, 19.11.): "Reisefotos
    /// sortiert" while only "Reisen" and "Länder und Orte" count (the standard), "Fotos sortiert"
    /// as soon as another area counts too; with "Nur 2026" "Reisefotos aus 2026 sortiert". The
    /// word "Hauptbereiche" leaves the start page.
    public enum Subject: Equatable, Sendable {
        case travelPhotos(year: Int?)
        case photos(year: Int?)

        /// The small "i" at the ring says what "sortiert" means for travel photos: "Sortiert
        /// heißt: in einem Album für Reise oder Land." (decision 8A).
        public var isTravel: Bool {
            if case .travelPhotos = self { true } else { false }
        }
    }

    public static func subject(settings: OrganizationSettings, scope: OrganizationScope) -> Subject {
        let year: Int? = if case .year(let year) = scope { year } else { nil }
        return countedAreas(settings).isSubset(of: [.trips, .places]) ? .travelPhotos(year: year) : .photos(year: year)
    }
}
