import Foundation
import ImageIO
import Photos
import Testing
import Vision
import SwiftUI
import UIKit
import SortlyCore
import SortlyEngine
@testable import Sortly

@Suite("Platform mapping")
struct PlatformMappingTests {
    @Test func subtypesMapToCoreFlags() {
        let mapped = PhotoKitLibrary.subtypes(from: [.photoScreenshot, .photoLive, .videoTimelapse])
        #expect(mapped.contains(.screenshot))
        #expect(mapped.contains(.livePhoto))
        #expect(mapped.contains(.timelapse))
        #expect(!mapped.contains(.panorama))
    }

    @Test func authorizationMapping() {
        #expect(PhotoKitLibrary.map(.authorized) == .full)
        #expect(PhotoKitLibrary.map(.limited) == .limited)
        #expect(PhotoKitLibrary.map(.denied) == .denied)
        #expect(!PhotoKitLibrary.map(.notDetermined).canRead)
    }
}

@Suite("Vision taxonomy")
struct VisionTaxonomyTests {
    /// Every category should map to at least one identifier the on-device classifier knows.
    /// Unknown identifiers are printed so the taxonomy can be corrected.
    @Test func taxonomyUsesKnownIdentifiers() throws {
        let supported: Set<String>
        do {
            supported = Set(try VNClassifyImageRequest().supportedIdentifiers())
        } catch {
            print("Vision identifiers not available in this environment: \(error)")
            return
        }
        guard !supported.isEmpty else { return }
        var unknown: [String] = []
        var uncovered: [String] = []
        for category in ImageTaxonomy.all where !category.visionIdentifiers.isEmpty {
            let missing = category.visionIdentifiers.filter { !supported.contains($0) }
            unknown += missing.map { "\(category.id): \($0)" }
            if missing.count == category.visionIdentifiers.count { uncovered.append(category.id) }
        }
        print("TAXONOMY unknown identifiers (\(unknown.count)): \(unknown.joined(separator: ", "))")
        print("TAXONOMY categories without any known identifier: \(uncovered.joined(separator: ", "))")
        #expect(uncovered.count * 5 <= ImageTaxonomy.all.count, "Too many categories cannot be recognized")
    }
}

@Suite("Texts")
struct TextTests {
    @Test func reasonTextsAreFilled() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let text = ReasonText.text(.photosInPeriod(count: 12, start: start, end: start.addingTimeInterval(86_400)))
        #expect(text.contains("12"))
        #expect(!ReasonText.text(.noExistingAlbum).isEmpty)
    }

    @Test func conflictTextsUseAlbumTitles() {
        let id = CollectionID("album-1")
        let inventory = CollectionInventory([
            CollectionSnapshot(id: id, title: "Italien 2023", kind: .userAlbum, capabilities: .all, parentID: nil, assetIDs: [], childIDs: [])
        ])
        #expect(ConflictText.text(.albumMissing(id), inventory: inventory).contains("Italien 2023"))
    }
}

@Suite("Atlas rendering")
@MainActor
struct AtlasRenderingTests {
    static func sampleAtlas() -> TravelAtlas {
        var atlas = TravelAtlas()
        let codes = ["AT", "IT", "FR", "ES", "PT", "HR", "GR", "GB", "NL", "US", "TH", "JP", "MA", "NO", "IS", "CH", "CZ", "DK", "MX", "AU", "EG", "TR", "DE"]
        atlas.countryCodes = Set(codes)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        for (i, code) in codes.enumerated() {
            atlas.firstVisits[code] = calendar.date(from: DateComponents(year: 2012 + i / 2, month: 1 + i % 12, day: 10))
        }
        atlas.cityCount = 61
        atlas.tripCount = 48
        atlas.sinceYear = 2012
        atlas.longestTripDays = 16
        atlas.favoriteTripCity = "Rom"
        return atlas
    }

    /// CI logs drop very long lines, so the image is printed in numbered chunks.
    /// `data` is nil when the simulator's JPEG encoder fails ("session write failed", seen on
    /// CI once): the preview is skipped instead of crashing the whole test run.
    static func emit(_ name: String, _ data: Data?) {
        guard let data else {
            print("PREVIEW_SKIPPED \(name): JPEG encoding failed")
            return
        }
        let text = data.base64EncodedString()
        let size = 4000
        let total = (text.count + size - 1) / size
        var index = 0
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            print("PREVIEW_JPEG \(name) \(index + 1)/\(total) \(text[start..<end])")
            start = end
            index += 1
        }
    }

    /// Stand-in for a holiday photo (the simulator has no real library in tests):
    /// evening sky, sea and a few houses on a hill.
    static func sampleCover() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1080, height: 720)).image { ctx in
            let cg = ctx.cgContext
            let space = CGColorSpaceCreateDeviceRGB()
            let sky = CGGradient(colorsSpace: space, colors: [UIColor(red: 0.35, green: 0.55, blue: 0.85, alpha: 1).cgColor,
                                                              UIColor(red: 1.0, green: 0.78, blue: 0.55, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: 470), options: [])
            UIColor(red: 1, green: 0.93, blue: 0.75, alpha: 1).setFill()
            cg.fillEllipse(in: CGRect(x: 700, y: 330, width: 120, height: 120))
            let sea = CGGradient(colorsSpace: space, colors: [UIColor(red: 0.16, green: 0.42, blue: 0.62, alpha: 1).cgColor,
                                                              UIColor(red: 0.05, green: 0.22, blue: 0.38, alpha: 1).cgColor] as CFArray, locations: [0, 1])!
            cg.saveGState(); cg.clip(to: CGRect(x: 0, y: 470, width: 1080, height: 250))
            cg.drawLinearGradient(sea, start: CGPoint(x: 0, y: 470), end: CGPoint(x: 0, y: 720), options: []); cg.restoreGState()
            UIColor(red: 0.42, green: 0.36, blue: 0.28, alpha: 1).setFill()
            let hill = UIBezierPath()
            hill.move(to: CGPoint(x: 0, y: 520)); hill.addQuadCurve(to: CGPoint(x: 520, y: 520), controlPoint: CGPoint(x: 230, y: 300))
            hill.addLine(to: CGPoint(x: 520, y: 720)); hill.addLine(to: CGPoint(x: 0, y: 720)); hill.close(); hill.fill()
            let houses: [(CGFloat, CGFloat, UIColor)] = [(90, 420, .init(red: 0.95, green: 0.85, blue: 0.70, alpha: 1)), (170, 395, .init(red: 0.93, green: 0.62, blue: 0.42, alpha: 1)),
                                                         (250, 385, .init(red: 0.98, green: 0.92, blue: 0.80, alpha: 1)), (330, 400, .init(red: 0.86, green: 0.55, blue: 0.40, alpha: 1))]
            for (x, y, color) in houses { color.setFill(); cg.fill(CGRect(x: x, y: y, width: 64, height: 70)) }
        }
    }

    /// Renders the share card and the atlas screen and prints them as JPEG (base64) into
    /// the CI log, so the design can be reviewed without a Mac.
    @Test func renderPreviews() async throws {
        let outlines = await AtlasOutlines.shared.load(from: nil)
        #expect(outlines.count > 200)
        let atlas = Self.sampleAtlas()

        for (name, cover) in [("sharecard", Self.sampleCover()), ("sharecard-nophoto", nil)] as [(String, UIImage?)] {
            let card = ImageRenderer(content: ShareCard(atlas: atlas, sortedPhotos: 12_480, outlines: outlines, cover: cover))
            card.scale = 1
            let cardImage = try #require(card.uiImage)
            #expect(cardImage.size == CGSize(width: 720, height: 1280))
            Self.emit(name, cardImage.jpegData(compressionQuality: 0.8))
        }

        for scheme in [ColorScheme.light, .dark] {
            let screen = ImageRenderer(content:
                AtlasContent(atlas: atlas, outlines: outlines, revealed: 14)
                    .padding(16)
                    .frame(width: 393)
                    .background(Theme.background)
                    .environment(\.colorScheme, scheme)
            )
            screen.scale = 2
            let screenImage = try #require(screen.uiImage)
            Self.emit(scheme == .light ? "atlas" : "atlas-dark", screenImage.jpegData(compressionQuality: 0.7))
        }
    }
}

@Suite("English localization")
struct LocalizationTests {
    private var english: Bundle? {
        Bundle.main.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:))
    }

    @Test func appShipsEnglish() throws {
        let bundle = try #require(english, "en.lproj missing; localizations: \(Bundle.main.localizations)")
        #expect(bundle.localizedString(forKey: "Abbrechen", value: nil, table: nil) == "Cancel")
        #expect(bundle.localizedString(forKey: "Deine Fotos, endlich sortiert.", value: nil, table: nil) == "Your photos, finally sorted.")
        let format = bundle.localizedString(forKey: "%lld Fotos", value: nil, table: nil)
        #expect(String.localizedStringWithFormat(format, 1) == "1 photo")
        #expect(String.localizedStringWithFormat(format, 3) == "3 photos")
        let twoArgs = bundle.localizedString(forKey: "%@ von %@", value: nil, table: nil)
        #expect(String(format: twoArgs, "3", "7") == "3 of 7")
    }

    /// German singular forms ("1 Reise", not "1 Reisen") come from the catalog's plural variations.
    @Test func germanSingulars() throws {
        let path = try #require(Bundle.main.path(forResource: "de", ofType: "lproj"), "de.lproj missing")
        let bundle = try #require(Bundle(path: path))
        for (key, one, many) in [("%lld Fotos", "1 Foto", "2 Fotos"), ("%lld Reisen", "1 Reise", "2 Reisen"),
                                 ("%lld Länder", "1 Land", "2 Länder"), ("%lld Vorschläge", "1 Vorschlag", "2 Vorschläge")] {
            let format = bundle.localizedString(forKey: key, value: nil, table: nil)
            #expect(String.localizedStringWithFormat(format, 1) == one)
            #expect(String.localizedStringWithFormat(format, 2) == many)
        }
    }

    @Test func germanStaysSource() {
        #expect(Bundle.main.developmentLocalization == "de")
    }
}

/// "Dein Zuhause": how homes and places are called (`HomeText`), and the English of its texts.
@Suite("Dein Zuhause texts")
struct HomeTextTests {
    static let munich = PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern", locality: "München")
    static let offline = PlaceComponents(isoCountryCode: "DE", country: "Deutschland", administrativeArea: "Bayern")

    @Test func areaNamesTheTownOrOfflineTheRegion() {
        #expect(HomeText.area(Self.munich).contains("München"))
        #expect(!HomeText.area(Self.munich).contains("Bayern"))
        #expect(HomeText.area(Self.offline).contains("Bayern"))
        #expect(!HomeText.area(nil).isEmpty)
        #expect(HomeText.short(Self.munich) == "München")
        #expect(HomeText.short(Self.offline) == "Bayern")
    }

    @Test func summaryFollowsTheSettings() {
        let place = HomePlace(center: GeoCoordinate(latitude: 48.137, longitude: 11.575), components: Self.munich)
        #expect(HomeText.summary(HomeSettings(), detected: place) == "München")
        #expect(HomeText.summary(HomeSettings().confirming(place, date: .now), detected: nil) == "München")
        let none = HomeText.summary(HomeSettings().withoutHome(date: .now), detected: place)
        #expect(none != "München" && !none.isEmpty)
        #expect(!HomeText.summary(HomeSettings(), detected: nil).isEmpty)
    }

    /// The last day lived there is shown, not the day after.
    @Test func formerHomeShowsTheLastMonth() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let until = calendar.date(from: DateComponents(year: 2019, month: 1, day: 1))!
        let home = FormerHome(place: HomePlace(center: GeoCoordinate(latitude: 53.55, longitude: 9.99), components: .init(locality: "Hamburg")), until: until)
        let line = HomeText.former(home)
        #expect(line.contains("Hamburg"))
        #expect(line.contains("2018"))
    }

    /// The user's own name first, then what the place is, then the place's name.
    @Test func placeTitles() {
        let base = PlaceAnswer(id: SortlyID("a"), center: GeoCoordinate(latitude: 45.6, longitude: 10.7), oftenHere: true, name: "Malcesine", answeredAt: .now)
        #expect(HomeText.title(base, placeName: "Gardasee") == "Gardasee")
        var parents = base
        parents.kind = .parents
        #expect(HomeText.title(parents, placeName: "Gardasee") == HomeText.kind(.parents))
        var own = parents
        own.label = "Oma"
        #expect(HomeText.title(own, placeName: "Gardasee") == "Oma")
        #expect(Set(PersonalPlaceKind.allCases.map(HomeText.kind)).count == PersonalPlaceKind.allCases.count)
        #expect(Set(PersonalPlaceKind.allCases.map(HomeText.symbol)).count == PersonalPlaceKind.allCases.count)
    }

    @Test func englishTexts() throws {
        let path = try #require(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        #expect(bundle.localizedString(forKey: "Dein Zuhause", value: nil, table: nil) == "Your home")
        #expect(bundle.localizedString(forKey: "Kein Zuhause festlegen", value: nil, table: nil) == "Don't set a home")
        let area = bundle.localizedString(forKey: "%@ und Umgebung", value: nil, table: nil)
        #expect(String(format: area, "Munich") == "Munich and surroundings")
        let removed = bundle.localizedString(forKey: "%lld Vorschläge passen nicht mehr und sind weggefallen.", value: nil, table: nil)
        #expect(String.localizedStringWithFormat(removed, 1) == "1 suggestion no longer fits and was removed.")
        #expect(String.localizedStringWithFormat(removed, 3) == "3 suggestions no longer fit and were removed.")
    }
}

@Suite("Siri, Shortcuts and Spotlight")
@MainActor
struct IntentDataTests {
    private func photo(_ id: String, _ country: String?) -> AssetFacts {
        AssetFacts(asset: AssetSnapshot(id: AssetID(id)), place: country.map { PlaceComponents(isoCountryCode: $0) })
    }

    @Test func countriesMostPhotographedFirst() {
        let model = AppModel()
        model.facts = [photo("a", "it"), photo("b", "IT"), photo("c", "FR"), photo("d", nil), photo("e", "")]
        let countries = IntentData.countries(model)
        #expect(countries.map(\.id) == ["IT", "FR"])
        #expect(countries.map(\.photoCount) == [2, 1])
        #expect(countries.first?.name == AtlasStyle.countryName("IT"))
    }

    @Test func noSuggestionsBeforeAnalysis() {
        #expect(IntentData.suggestions(AppModel()).isEmpty)
    }

    @Test func intentTextsShipInEnglish() throws {
        let path = try #require(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        #expect(bundle.localizedString(forKey: "Fotos aus einem Land zeigen", value: nil, table: nil) == "Show photos from a country")
        #expect(bundle.localizedString(forKey: "Offene Vorschläge", value: nil, table: nil) == "Open suggestions")
    }
}

@Suite("Demo library")
@MainActor
struct DemoLibraryTests {
    @Test func rendersPhotosScreenshotsAndDocuments() throws {
        var rng = SeededRandom(seed: 1)
        let photo = DemoLibrary.crop(AtlasRenderingTests.sampleCover(), rng: &rng)
        // Pixel size, not points: UIKit reports CGFloat sizes that can be off by a rounding error.
        let pixels = try #require(photo.cgImage)
        #expect(Set([pixels.width, pixels.height]) == [1600, 1200])
        let png = DemoLibrary.screenshotPNG(["Bordkarte", "MUC → FCO"])
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let exif = properties?[kCGImagePropertyExifDictionary] as? [CFString: Any]
        print("DEMO_SCREENSHOT_EXIF \(String(describing: exif?[kCGImagePropertyExifUserComment]))")
        #expect(DemoLibrary.documentPhoto(["Rechnung"]).size == CGSize(width: 1500, height: 2000))
        #expect(DemoLibrary.shared.expectedCount > 200)
    }
}

/// Device test 15.11.: the Lock Screen bar came only for the first analysis of an app session,
/// because every request used the same identifier and iOS runs an identifier only once.
@Suite("Continued analysis identifiers")
struct ContinuedAnalysisIdentifierTests {
    @Test func everyRequestHasItsOwnIdentifierThatInfoPlistPermits() throws {
        let ids = (0..<50).map { _ in ContinuedAnalysis.makeIdentifier() }
        #expect(Set(ids).count == ids.count)
        let permitted = try #require(Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String])
        let wildcard = try #require(permitted.first { $0.hasSuffix(".*") })
        let prefix = String(wildcard.dropLast(1))
        for id in ids {
            #expect(id.hasPrefix(prefix))
            #expect(id.count > prefix.count)
            // Under the bundle identifier, as iOS requires for continued processing tasks.
            #expect(id.hasPrefix(try #require(Bundle.main.bundleIdentifier) + "."))
        }
    }
}

/// Device test 15.11. 22:57: the analysis had stopped, and the Lock Screen still said
/// "Albumist analysiert deine Fotos". Every way a run ends gets its own text there.
@MainActor
@Suite("Lock Screen text when a run ends")
struct ContinuedAnalysisEndingTests {
    private func state(complete: Bool = false, paused: PauseReason? = nil, needsResume: Bool) -> AppModel.AnalysisState {
        var report = AnalysisPipeline.Report()
        if complete { report.completedStages = AnalysisPipeline.Stage.allCases }
        report.pausedBecause = paused
        var state = AppModel.AnalysisState()
        state.lastReport = report
        state.needsResume = needsResume
        return state
    }

    @Test func finishedSaysSoAndFillsTheCircle() {
        let ending = ContinuedAnalysis.ending(state(complete: true, needsResume: false))
        #expect(ending.title == String(localized: "Analyse fertig"))
        #expect(ending.complete)
    }

    @Test func pausedByTheUserSaysPaused() {
        let ending = ContinuedAnalysis.ending(state(paused: .userPaused, needsResume: false))
        #expect(ending.title == String(localized: "Analyse pausiert"))
        #expect(!ending.complete)
    }

    @Test func stoppedByTheDeviceOrIOSWaitsForTheUser() {
        for reason in [PauseReason.thermal, .batteryLow, .lowPower, .timeBudget, .accessRevoked] {
            let ending = ContinuedAnalysis.ending(state(paused: reason, needsResume: true))
            #expect(ending.title == String(localized: "Analyse wartet auf dich"), "\(reason)")
            #expect(!ending.complete)
        }
    }

    /// Point 5: "Analyse fertig" with the number of suggestions under it.
    @Test func finishedSaysHowManySuggestions() {
        var analysis = state(complete: true, needsResume: false)
        analysis.lastReport?.proposals = 216
        let ending = ContinuedAnalysis.ending(analysis)
        #expect(ending.title == String(localized: "Analyse fertig"))
        #expect(ending.subtitle == String(localized: "\(216) Vorschläge"))
    }

    /// An error leaves the report of the run before: a finished one must not read as "fertig".
    @Test func anErrorAfterAFinishedRunIsNotFinished() {
        let ending = ContinuedAnalysis.ending(state(complete: true, needsResume: true))
        #expect(ending.title == String(localized: "Analyse wartet auf dich"))
        #expect(!ending.complete)
    }
}

/// Point 5 and the card's texts (progress display v3): number first, the finish time only when
/// there is one to trust, never while the run waits.
@MainActor
@Suite("Analysis card and Lock Screen texts")
struct AnalysisTextTests {
    private func running(_ step: AnalysisPipeline.Stage = .content, completed: Int = 2_431, total: Int = 5_683) -> AppModel.AnalysisState {
        var state = AppModel.AnalysisState()
        state.isRunning = true
        state.stage = step
        state.completed = completed
        state.total = total
        return state
    }

    @Test func lockScreenNumberFirstThenFinishTime() {
        let today = Calendar.current.date(bySettingHour: 23, minute: 40, second: 0, of: Date()) ?? Date()
        let count = AnalysisText.count(.init(step: .content, completed: 2_431, total: 5_683))
        #expect(count.hasPrefix(2_431.formatted()))
        #expect(count.contains(5_683.formatted()))
        let withTime = ContinuedAnalysis.subtitle(running(), finish: .at(today))
        #expect(withTime.hasPrefix(count))
        #expect(withTime.contains(AnalysisText.time(today)))
        // Without a time to trust: the count only.
        #expect(ContinuedAnalysis.subtitle(running(), finish: nil) == count)
        // Waiting: no time, the reason.
        var waiting = running()
        waiting.waiting = .batteryLow
        #expect(ContinuedAnalysis.subtitle(waiting, finish: .at(today)) == String(localized: "Wartet aufs Laden"))
        // A step without a count says the step.
        #expect(ContinuedAnalysis.subtitle(running(.groups, completed: 0, total: 0), finish: nil)
                == String(localized: "Schritt \(6) von \(6)"))
    }

    @Test func unitsFollowTheStepWithSingular() {
        #expect(AnalysisText.ofTotal(1, .photos) == String(localized: "von \(1) Fotos"))
        #expect(AnalysisText.ofTotal(1_600, .places) == String(localized: "von \(1_600) Orten"))
        #expect(AnalysisText.ofTotal(1_040, .screenshots) == String(localized: "von \(1_040) Screenshots"))
        #expect(AnalysisText.ofTotal(1, .photos) != AnalysisText.ofTotal(2, .photos).replacingOccurrences(of: "2", with: "1"))
    }

    @Test func finishTimeTodayTomorrowAndSoon() {
        let now = Calendar.current.date(bySettingHour: 22, minute: 55, second: 0, of: Date()) ?? Date()
        let later = now.addingTimeInterval(45 * 60)
        let tomorrow = now.addingTimeInterval(8 * 3_600)
        #expect(AnalysisText.finish(.at(later), now: now) == String(localized: "Fertig gegen \(AnalysisText.time(later))"))
        #expect(AnalysisText.finish(.at(tomorrow), now: now) == String(localized: "Fertig morgen gegen \(AnalysisText.time(tomorrow))"))
        #expect(AnalysisText.finish(.soon, now: now) == String(localized: "Gleich fertig"))
    }

    @Test func alreadyDoneLeavesZerosOut() {
        #expect(AnalysisText.alreadyDone(AlreadyDone(trips: 51, places: 38))
                == String(localized: "\(51) Reisen") + ", " + String(localized: "\(38) Orte"))
        #expect(AnalysisText.alreadyDone(AlreadyDone(trips: 0, places: 3)) == String(localized: "\(3) Orte"))
    }
}

/// Counts in catalog sentences stay plain integers (`%lld` keys with plural forms). A thousands
/// separator needs its own catalog keys first (docs/IMPROVEMENTS.md).
struct CountFormattingTests {
    /// Run 43796534873: `format: .number` turned the key into one the catalog does not have, so
    /// the English overview showed "57 Fotos von zu Hause". The plain count must find the key.
    @Test func countLinesFindTheirCatalogKeyAndPlurals() {
        let one = 1, many = 1354
        let single = String(localized: "\(one) Fotos von zu Hause", locale: Locale(identifier: "de_DE"))
        let plural = String(localized: "\(many) Fotos von zu Hause", locale: Locale(identifier: "de_DE"))
        print("COUNT_FORMAT \(single) | \(plural)")
        // The test host may run in English or German: the singular form proves the key (and its
        // plural variations) was found; an untranslated key would keep "Fotos" for one photo.
        #expect(single.hasPrefix("1 ") && !single.contains("Fotos") && !single.contains("photos"))
        #expect(plural.contains("Fotos") || plural.contains("photos"))
    }
}

/// Fuchs 16.11. ("Ja"): after "Analyse neu aufbauen" or another part of the library, the photo
/// mosaic comes back, because the next run counts as a first analysis again.
@MainActor
struct MosaicAfterRebuildTests {
    @Test func rebuildMakesTheNextRunAFirstAnalysisAgain() {
        let key = "analysis.completedOnce"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        AnalysisMarker.finished()
        #expect(AnalysisMarker.completedOnce)
        #expect(!ScanShowRule.shows(isRunning: true, firstAnalysis: !AnalysisMarker.completedOnce, isQuickCheck: false))

        AnalysisMarker.reset()   // what "Analyse neu aufbauen" and another library part call
        #expect(!AnalysisMarker.completedOnce)
        #expect(ScanShowRule.shows(isRunning: true, firstAnalysis: !AnalysisMarker.completedOnce, isQuickCheck: false))
    }
}
