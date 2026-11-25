#if targetEnvironment(simulator)
import AVFoundation
import CoreLocation
import ImageIO
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Simulator only (browser testing on Appetize, App Store screenshots): fills the empty
/// simulator library with a realistic example library. Travel photos are crops of the
/// simulator's own sample photos with dates and GPS of real trips; screenshots and
/// paper documents are rendered text; one short video at home (`clip`). Never part of a
/// device build.
@MainActor
@Observable
final class DemoLibrary {
    static let shared = DemoLibrary()

    private(set) var isSeeding = false
    private(set) var created = 0
    private(set) var total = 0
    private(set) var isDone = UserDefaults.standard.bool(forKey: "demo.seeded")

    struct Spot { var lat: Double; var lon: Double }
    struct Trip { var spot: Spot; var year: Int; var month: Int; var day: Int; var days: Int; var photos: Int }

    static let home = Spot(lat: 48.1374, lon: 11.5755)          // München
    static let grandma = Spot(lat: 48.3520, lon: 11.7930)       // a second frequent place
    static let trips: [Trip] = [
        Trip(spot: Spot(lat: 48.8566, lon: 2.3522), year: 2018, month: 10, day: 5, days: 3, photos: 12),      // Paris
        Trip(spot: Spot(lat: 41.3874, lon: 2.1686), year: 2019, month: 6, day: 20, days: 5, photos: 14),     // Barcelona
        Trip(spot: Spot(lat: 40.7128, lon: -74.0060), year: 2019, month: 11, day: 2, days: 6, photos: 16),   // New York
        Trip(spot: Spot(lat: 48.2082, lon: 16.3738), year: 2020, month: 2, day: 21, days: 2, photos: 10),     // Wien
        Trip(spot: Spot(lat: 62.1008, lon: 7.2059), year: 2021, month: 7, day: 12, days: 5, photos: 14),     // Geiranger
        Trip(spot: Spot(lat: 43.5081, lon: 16.4402), year: 2021, month: 8, day: 20, days: 7, photos: 14),    // Split
        Trip(spot: Spot(lat: 38.7223, lon: -9.1393), year: 2022, month: 4, day: 14, days: 4, photos: 12),    // Lissabon
        Trip(spot: Spot(lat: 43.7696, lon: 11.2558), year: 2022, month: 9, day: 3, days: 3, photos: 11),      // Florenz
        Trip(spot: Spot(lat: 55.6761, lon: 12.5683), year: 2023, month: 5, day: 18, days: 3, photos: 10),     // Kopenhagen
        Trip(spot: Spot(lat: 64.1466, lon: -21.9426), year: 2023, month: 8, day: 1, days: 4, photos: 12),    // Reykjavík
        Trip(spot: Spot(lat: 63.4186, lon: -19.0060), year: 2023, month: 8, day: 5, days: 3, photos: 10),     // Vík
        Trip(spot: Spot(lat: 41.8902, lon: 12.4922), year: 2024, month: 5, day: 10, days: 5, photos: 20),    // Rom
        Trip(spot: Spot(lat: 35.0116, lon: 135.7681), year: 2024, month: 10, day: 8, days: 6, photos: 16),   // Kyoto
    ]

    static let screenshots: [[String]] = [
        ["Bestellung bestätigt", "Bestellnummer 304-1188274", "Wanderschuhe, Größe 43", "Lieferung: Donnerstag", "Gesamtbetrag: 89,90 €"],
        ["Bordkarte", "MUC → FCO", "Flug SX 1234", "Sitz 14A · Gate G22", "Boarding 07:35"],
        ["Rezept: Pasta al limone", "200 g Spaghetti", "1 Bio-Zitrone", "50 g Parmesan", "Butter, Pfeffer, Salz"],
        ["Konzertticket", "Olympiahalle München", "Einlass 19:00 Uhr", "Block C · Reihe 12 · Platz 8"],
        ["Hotelbuchung bestätigt", "Hotel Campo de’ Fiori, Rom", "10.–15. Mai", "Buchungsnummer 77120934"],
        ["Bahnticket", "München Hbf → Salzburg Hbf", "Sparpreis · 2. Klasse", "Zug fährt 08:24 ab Gleis 12"],
        ["WLAN-Zugang", "Netzwerk: Ferienwohnung-Split", "Passwort: sonne2021"],
        ["Bestellung versandt", "Bestellnummer 112-5534", "Kaffeemaschine", "Sendungsnummer 00340434161094"],
    ]

    static let documents: [[String]] = [
        ["Rechnung Nr. 2024-118", "Stadtwerke Musterstadt", "Abrechnungszeitraum 01.01.–31.12.2024", "Strom 2.340 kWh", "Rechnungsbetrag 812,40 €"],
        ["Kassenbon", "Supermarkt am Markt", "Äpfel 2,49", "Brot 3,20", "Milch 1,19", "Summe EUR 6,88"],
        ["Garantiekarte", "Waschmaschine WM 8000", "Kaufdatum 14.03.2023", "Garantie bis 14.03.2025"],
        ["Rechnung Nr. 5531", "Autowerkstatt Huber", "Inspektion und Ölwechsel", "Gesamt 289,00 €"],
    ]

    var expectedCount: Int {
        Self.trips.reduce(0) { $0 + $1.photos } + 45 + 12 + Self.screenshots.count + Self.documents.count + 1 // the video
    }


    enum Spec {
        case photo(Spot, spread: Double, date: Date)
        case screenshot([String], date: Date)
        case document([String], date: Date)
    }

    /// Creates the example library and starts the analysis.
    func seed(then model: AppModel) async {
        guard !isSeeding else { return }
        isSeeding = true
        defer { isSeeding = false }
        created = 0
        var rng = SeededRandom(seed: 2026)
        let specs = Self.specs(&rng)
        // The photos, then one video (`clip`).
        total = specs.count + 1

        let sources = SourceImages(images: await Self.sampleImages())
        var number = 1000
        for start in stride(from: 0, to: specs.count, by: 15) {
            // Cropping, drawing and JPEG encoding take seconds per batch. Off the main actor,
            // so the app stays responsive while the demo library is written: on the main actor
            // the UI tests' accessibility queries timed out at the largest text size ("Failed
            // to get matching snapshots: Timed out while evaluating UI query", run 43856872524).
            // The random generator is handed through each batch in order, so the library stays
            // the same every time.
            let part = Array(specs[start..<min(start + 15, specs.count)])
            // Off the main actor (drawing a batch takes seconds). No priority of its own: the
            // task is awaited right here, which raises it to the priority of this task anyway.
            let made = await Task.detached { [rng, number] in
                Self.items(part, sources: sources, firstNumber: number, rng: rng)
            }.value
            rng = made.rng
            number += part.count
            let items = made.items
            do {
                try await Self.save(items)
                created += items.count
            } catch {
                model.message = .failure(error.localizedDescription)
                return
            }
            await Task.yield()
        }
        // One short video at home on a day of its own (design wave 3, DS-16): the grids show its
        // length, the photo view plays it, and the UI tests and screenshots have a video too.
        // Written off the main actor. A simulator that cannot encode it leaves the library
        // without it, as before.
        if let clip = await Task.detached(operation: { await Self.clip(from: sources) }).value {
            do {
                try await Self.save(video: clip, date: Self.date(2021, 3, 14, hour: 16, minute: 20), at: Self.home)
                created += 1
            } catch {
                try? FileManager.default.removeItem(at: clip)
            }
        }
        isDone = true
        UserDefaults.standard.set(true, forKey: "demo.seeded")
        model.startAnalysis(cause: .tap)
    }

    /// The photos of the example library, in order: the trips, everyday life at home, the visits
    /// to the same place, the screenshots and the paper documents.
    private static func specs(_ rng: inout SeededRandom) -> [Spec] {
        var specs: [Spec] = []
        for trip in trips {
            for i in 0..<trip.photos {
                specs.append(.photo(trip.spot, spread: 0.02, date: date(trip.year, trip.month, trip.day, plusDays: i % trip.days,
                                                                         hour: 9 + Int(rng.next(in: 0...10)), minute: Int(rng.next(in: 0...59)))))
            }
        }
        for i in 0..<45 {   // everyday life at home, spread over several years
            specs.append(.photo(home, spread: 0.03, date: date(2018 + i % 7, 1 + (i * 5) % 12, 1 + (i * 7) % 27,
                                                                hour: 10 + i % 9, minute: (i * 13) % 60)))
        }
        for i in 0..<12 {   // regular visits to the same place
            specs.append(.photo(grandma, spread: 0.0005, date: date(2020 + i % 5, 1 + (i * 3) % 12, 5 + i, hour: 15, minute: 10 + i)))
        }
        for (i, lines) in screenshots.enumerated() {
            specs.append(.screenshot(lines, date: date(2024, 1 + i, 3 + i, hour: 18, minute: 2 * i)))
        }
        for (i, lines) in documents.enumerated() {
            specs.append(.document(lines, date: date(2024, 2 + 2 * i, 10, hour: 20, minute: 15)))
        }
        return specs
    }

    /// The example library's calendar: its photos were taken in Germany.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }()

    private static func date(_ y: Int, _ m: Int, _ d: Int, plusDays: Int = 0, hour: Int, minute: Int) -> Date {
        let start = calendar.date(from: DateComponents(year: y, month: m, day: d, hour: hour, minute: minute))!
        return calendar.date(byAdding: .day, value: plusDays, to: start)!
    }

    /// Nonisolated on purpose: PhotoKit runs the change block on its own queue, and a
    /// main-actor closure there traps at runtime (Swift 6 isolation check).
    nonisolated static func save(_ items: [Item]) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            for item in items {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = item.name
                options.uniformTypeIdentifier = item.type.identifier
                request.addResource(with: .photo, data: item.data, options: options)
                request.creationDate = item.date
                request.location = item.location
            }
        }
    }

    /// The video into the library as the camera saves one: its file moves into Photos.
    /// Nonisolated for the same reason as `save(_:)`.
    nonisolated static func save(video url: URL, date: Date, at spot: Spot) async throws {
        let latitude = spot.lat, longitude = spot.lon
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = "IMG_2000.MOV"
            options.uniformTypeIdentifier = UTType.quickTimeMovie.identifier
            options.shouldMoveFile = true
            request.addResource(with: .video, fileURL: url, options: options)
            request.creationDate = date
            request.location = CLLocation(latitude: latitude, longitude: longitude)
        }
    }

    /// Nonisolated for the same reason: the result handler may arrive on a background queue.
    nonisolated static func requestImage(_ identifier: String, side: CGFloat) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = false
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                                  contentMode: .aspectFit, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    struct Item: @unchecked Sendable {
        var data: Data
        var type: UTType
        var name: String
        var date: Date
        var location: CLLocation?
    }
}

/// Small deterministic random generator, so the demo library is the same every time.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func nextUnit() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state >> 11) / Double(1 << 53)
    }
    mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + nextUnit() * (range.upperBound - range.lowerBound)
    }
}

/// Card in the overview and in settings (simulator only).
struct DemoLibraryCard: View {
    @Environment(AppModel.self) private var model
    @State private var demo = DemoLibrary.shared

    var body: some View {
        Card {
            Label("Demo", systemImage: "wand.and.stars").font(.headline)
            if demo.isDone {
                Text("Beispiel-Mediathek ist angelegt.").font(.subheadline).foregroundStyle(.noteText)
            } else if demo.isSeeding {
                ProgressView(value: Double(demo.created), total: Double(max(demo.total, 1)))
                Text("Beispielfotos werden angelegt: \(demo.created) von \(demo.total)")
                    .font(.subheadline).foregroundStyle(.noteText).monospacedDigit()
            } else {
                Text("Legt etwa \(demo.expectedCount) Beispielfotos mit Reisen, Screenshots und Dokumenten an. Nur im Simulator.")
                    .font(.subheadline).foregroundStyle(.noteText)
                Button("Beispiel-Mediathek anlegen") {
                    Task { await demo.seed(then: model) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.access.canRead)
            }
        }
    }
}
#endif
