#if DEBUG && targetEnvironment(simulator)
import CoreLocation
import Foundation
import UIKit

/// `-SortlyUITestLargeLibrary 3000` (simulator, UI tests only): a library of real size on top of
/// the demo library, to find what gets slow in lists and on the overview before a user with
/// 15 000 photos does. The photos are small (the analysis looks at small previews anyway) and
/// each one is different, with dates and places of 120 trips to 40 cities and of days at home.
/// They are created once per simulator; a later launch with the flag adds only what is missing.
enum LargeLibrary {
    private static let createdKey = "uitest.largeLibrary.created"

    static let cities: [(lat: Double, lon: Double)] = [
        (48.8566, 2.3522), (41.3874, 2.1686), (40.7128, -74.0060), (48.2082, 16.3738), (62.1008, 7.2059),
        (43.5081, 16.4402), (38.7223, -9.1393), (43.7696, 11.2558), (55.6761, 12.5683), (64.1466, -21.9426),
        (41.8902, 12.4922), (35.0116, 135.7681), (51.5072, -0.1276), (52.5200, 13.4050), (45.4408, 12.3155),
        (37.9838, 23.7275), (50.0755, 14.4378), (47.4979, 19.0402), (59.3293, 18.0686), (60.1699, 24.9384),
        (53.3498, -6.2603), (55.9533, -3.1883), (40.4168, -3.7038), (37.3891, -5.9845), (43.2965, 5.3698),
        (45.7640, 4.8357), (46.2044, 6.1432), (47.3769, 8.5417), (50.8503, 4.3517), (52.3676, 4.9041),
        (34.0522, -118.2437), (37.7749, -122.4194), (25.7617, -80.1918), (19.4326, -99.1332), (-33.8688, 151.2093),
        (-37.8136, 144.9631), (1.3521, 103.8198), (13.7563, 100.5018), (22.3193, 114.1694), (35.6762, 139.6503),
    ]

    /// Creates what is missing of `count` photos; true when photos were added.
    @MainActor
    static func createIfNeeded(count: Int) async -> Bool {
        let created = UserDefaults.standard.integer(forKey: createdKey)
        guard created < count else { return false }
        for start in stride(from: created, to: count, by: 100) {
            let range = start..<min(start + 100, count)
            let items = await Task.detached(priority: .userInitiated) { range.map { LargeLibrary.item($0) } }.value
            do {
                try await DemoLibrary.save(items)
            } catch {
                return start > created
            }
            UserDefaults.standard.set(range.upperBound, forKey: createdKey)
        }
        return true
    }

    /// Photo number `index`: 25 photos per trip over five days; every fifth trip is a stretch of
    /// days at home in München.
    nonisolated static func item(_ index: Int) -> DemoLibrary.Item {
        var rng = SeededRandom(seed: UInt64(index) &+ 3_000)
        let trip = index / 25
        let spot = trip % 5 == 4 ? (lat: 48.1374, lon: 11.5755) : cities[trip % cities.count]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let start = calendar.date(from: DateComponents(year: 2010 + trip % 15, month: 1 + (trip * 7) % 12, day: 1 + (trip * 3) % 25,
                                                       hour: 9 + index % 10, minute: (index * 13) % 60))!
        let date = calendar.date(byAdding: .day, value: (index % 25) / 5, to: start)!
        let location = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: spot.lat + rng.next(in: -0.02...0.02), longitude: spot.lon + rng.next(in: -0.02...0.02)),
            altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10, timestamp: date)
        return DemoLibrary.Item(data: image(&rng), type: .jpeg, name: "IMG_\(20_000 + index).JPG", date: date, location: location)
    }

    /// A small picture of coloured shapes, different for every photo.
    nonisolated static func image(_ rng: inout SeededRandom) -> Data {
        let size = CGSize(width: 192, height: 144)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        var shapes: [(CGRect, UIColor)] = []
        let background = UIColor(hue: CGFloat(rng.nextUnit()), saturation: 0.45, brightness: 0.85, alpha: 1)
        for _ in 0..<7 {
            let rect = CGRect(x: rng.next(in: 0...150), y: rng.next(in: 0...110), width: rng.next(in: 12...90), height: rng.next(in: 12...70))
            shapes.append((rect, UIColor(hue: CGFloat(rng.nextUnit()), saturation: 0.7, brightness: CGFloat(rng.next(in: 0.3...1)), alpha: 1)))
        }
        let picture = UIGraphicsImageRenderer(size: size, format: format).image { context in
            background.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for (rect, color) in shapes {
                color.setFill()
                UIBezierPath(ovalIn: rect).fill()
            }
        }
        return picture.jpegData(compressionQuality: 0.7) ?? Data()
    }
}
#endif
