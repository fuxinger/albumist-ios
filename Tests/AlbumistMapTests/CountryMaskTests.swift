import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap
import AlbumistWorldMap

/// The visited countries' mask for our own globe (`CountryMask`): the atlas's fill, disputed
/// areas cut out, across the antimeridian, from the real offline map and from made-up shapes.
@Suite("Country mask")
struct CountryMaskTests {
    static let map: OfflineWorldMap = try! WorldMapResource.load()
    /// The app's shapes (`AtlasOutlines`: 0.3° steps).
    static let shapes = AtlasShapes.make(from: map, minimumStepDegrees: 0.3)
    static let everyCode = Set(shapes.map(\.code).filter { !$0.isEmpty })

    func at(_ latitude: Double, _ longitude: Double) -> GeoCoordinate { GeoCoordinate(latitude: latitude, longitude: longitude) }

    // MARK: Real map

    @Test func icelandIsTintedAndTheAtlanticIsNot() {
        let mask = CountryMask.build(shapes: Self.shapes, visited: ["IS"])
        #expect(mask.width == 2_048 && mask.height == 1_024 && mask.pixels.count == 2_048 * 1_024)
        for (latitude, longitude) in [(64.8, -18.0), (65.2, -20.0), (64.5, -16.0), (65.5, -15.5), (64.1, -21.5)] {
            let isTinted = mask.isTinted(at(latitude, longitude))
            #expect(isTinted, "\(latitude), \(longitude)")
        }
        for (latitude, longitude) in [(60.0, -25.0), (62.0, -7.0), (70.0, -40.0), (51.5, -0.12), (66.6, -26)] {
            let isTinted = mask.isTinted(at(latitude, longitude))
            #expect(!isTinted, "\(latitude), \(longitude)")
        }
        // About Iceland's 103,000 km², at about 160 km² a pixel up there.
        #expect((450...850).contains(mask.tintedPixelCount), "\(mask.tintedPixelCount)")
        // Nothing but Iceland: every tinted pixel lies within its box.
        for row in 0..<mask.height {
            for column in 0..<mask.width where mask.value(column: column, row: row) > 0 {
                let c = CountryMask.center(column: column, row: row, width: mask.width, height: mask.height)
                #expect(c.latitude > 63 && c.latitude < 67 && c.longitude > -25 && c.longitude < -13)
            }
        }
        #expect(CountryMask.build(shapes: Self.shapes, visited: []).tintedPixelCount == 0)
    }

    @Test func disputedAreasAreNeverTinted() {
        let visited: Set<String> = ["RU", "UA", "IN", "PK", "CN", "MA", "IL", "GE", "CY", "RS", "TW", "XK", "EH"]
        let mask = CountryMask.build(shapes: Self.shapes, visited: visited)
        // Inland places (the shapes' coasts are simplified to 0.3° steps, so a port can lie in the sea).
        let tinted = [("Moskau", 55.7558, 37.6173), ("Kiew", 50.4501, 30.5234), ("Delhi", 28.6139, 77.2090), ("Lahore", 31.5204, 74.3587),
                      ("Peking", 39.9042, 116.4074), ("Fès", 34.0331, -5.0003), ("Be'er Sheva", 31.2518, 34.7913), ("Tiflis", 41.7151, 44.8271),
                      ("Troodos", 34.9361, 32.8636), ("Belgrad", 44.7866, 20.4489)]
        for (name, latitude, longitude) in tinted {
            let isTinted = mask.isTinted(at(latitude, longitude))
            let filled = AtlasShapes.filledCode(at: at(latitude, longitude), in: Self.shapes, visited: visited)
            #expect(isTinted && filled != nil, "\(name): \(filled ?? "nichts")")
        }
        // Crimea, Western Sahara, the Golan, Abkhazia, Kashmir, Taiwan, Kosovo, Northern Cyprus.
        let untinted = [("Simferopol", 44.9521, 34.1024), ("Laâyoune", 27.1536, -13.2033), ("Golan", 33.0, 35.75), ("Sochumi", 43.0015, 41.0234),
                        ("Srinagar", 34.0837, 74.7973), ("Taipeh", 25.0330, 121.5654), ("Pristina", 42.6629, 21.1655), ("Kyrenia", 35.3417, 33.3192)]
        for (name, latitude, longitude) in untinted {
            let isTinted = mask.isTinted(at(latitude, longitude))
            let filled = AtlasShapes.filledCode(at: at(latitude, longitude), in: Self.shapes, visited: visited)
            #expect(!isTinted && filled == nil, "\(name): \(filled ?? "nichts")")
        }
    }

    @Test func russiaAndFijiFillAcrossTheAntimeridian() {
        let mask = CountryMask.build(shapes: Self.shapes, visited: ["RU", "FJ"])
        // Chukotka east of 180°, Wrangel Island on both sides of it, Viti Levu and Vanua Levu.
        let inside = [(66.0, -172.5), (65.5, 176.0), (71.2, 179.5), (71.2, -179.5), (-17.8, 178.0), (-16.5, 179.5)]
        for (latitude, longitude) in inside {
            #expect(AtlasShapes.filledCode(at: at(latitude, longitude), in: Self.shapes, visited: ["RU", "FJ"]) != nil, "\(latitude), \(longitude)")
            #expect(mask.isTinted(at(latitude, longitude)), "\(latitude), \(longitude)")
        }
        // The far columns hold Russia at Wrangel's latitude, the sea between is not tinted, and no
        // row is filled across the map (a ring wrapped the wrong way would fill a whole row).
        let row = mask.pixel(of: at(71.2, 179.9))!.row
        #expect(mask.value(column: 0, row: row) > 0 && mask.value(column: mask.width - 1, row: row) > 0)
        #expect(!mask.isTinted(at(71.2, 0)) && !mask.isTinted(at(71.2, -160)) && !mask.isTinted(at(-17.0, -170)))
        var widest = 0
        for r in 0..<mask.height {
            widest = max(widest, (0..<mask.width).filter { mask.value(column: $0, row: r) > 0 }.count)
        }
        #expect(widest > 500 && widest < 1_200, "\(widest)")
    }

    /// Pixel by pixel the mask is what the atlas fills (`AtlasShapes.filledCode` at each pixel's
    /// centre), sampled over the whole map with every country visited.
    @Test func theMaskIsTheAtlasFill() {
        let mask = CountryMask.build(shapes: Self.shapes, visited: Self.everyCode)
        var compared = 0, different: [String] = []
        for row in stride(from: 3, to: mask.height, by: 9) {
            for column in stride(from: 5, to: mask.width, by: 13) {
                let c = CountryMask.center(column: column, row: row, width: mask.width, height: mask.height)
                let atlas = AtlasShapes.filledCode(at: c, in: Self.shapes, visited: Self.everyCode) != nil
                if atlas != (mask.value(column: column, row: row) > 0) { different.append("\(c.latitude), \(c.longitude)") }
                compared += 1
            }
        }
        #expect(compared > 15_000)
        #expect(different.isEmpty, "\(different.count): \(different.prefix(5))")
        // About a third of the map's pixels are land, most of it a country (Antarctica is none).
        let share = Double(mask.tintedPixelCount) / Double(mask.pixels.count)
        #expect(share > 0.2 && share < 0.35, "\(share)")
    }

    /// The work grows with the map's edges and the rows they cross, never with rows times points.
    @Test func theFillDoesLinearWork() {
        let start = Date()
        let mask = CountryMask.build(shapes: Self.shapes, visited: Self.everyCode)
        let seconds = Date().timeIntervalSince(start)
        let points = Self.shapes.reduce(0) { $0 + $1.rings.reduce(0) { $0 + $1.count } }
        #expect(mask.work.edges <= points)
        #expect(mask.work.crossings < 40 * points, "\(mask.work.crossings) crossings for \(points) points")
        #expect(mask.work.rows < 1_024 * 80)
        #expect(mask.work.pixelsWritten >= mask.tintedPixelCount)
        print("Country mask, every country: \(Int(seconds * 1_000)) ms (debug build), \(mask.work.edges) edges, \(mask.work.rows) rows, \(mask.work.crossings) crossings, \(mask.work.pixelsWritten) pixels")
    }

    // MARK: Made-up shapes

    func square(_ south: Double, _ west: Double, _ north: Double, _ east: Double) -> [GeoCoordinate] {
        [at(south, west), at(south, east), at(north, east), at(north, west)]
    }

    @Test func squaresHolesAndCuts() {
        let shapes = [
            // A country with a hole (even-odd over its two rings), and an island of it.
            AtlasShape(code: "AA", rings: [square(10, 30, 20, 40), square(13, 33, 17, 37), square(-5, -5, -1, -1)]),
            // Its neutral area along its south.
            AtlasShape(code: "", rings: [square(9, 29, 12, 41)], neutralOver: ["AA"], disputedArea: "test"),
            // A neutral area over another country only: never cut from AA.
            AtlasShape(code: "", rings: [square(17.5, 38, 19, 45)], neutralOver: ["CC"], disputedArea: "other"),
            // A country nobody visited, beside it.
            AtlasShape(code: "BB", rings: [square(10, 41, 20, 50)]),
            // A shape without a code (a disputed area drawn as a country).
            AtlasShape(code: "", rings: [square(30, 30, 35, 35)], disputedArea: "own"),
        ]
        let mask = CountryMask.build(shapes: shapes, visited: ["AA", ""], width: 720, height: 360)
        #expect(mask.isTinted(at(14, 31)) && mask.isTinted(at(19, 39)) && mask.isTinted(at(18.5, 39.5)))
        #expect(mask.isTinted(at(-3, -3)))
        #expect(!mask.isTinted(at(15, 35)))   // the hole
        #expect(!mask.isTinted(at(10.5, 35)))  // cut out by its neutral area
        #expect(!mask.isTinted(at(15, 45)) && !mask.isTinted(at(32, 32)) && !mask.isTinted(at(25, 35)))
        // Exactly the pixels whose centres lie inside: 20 × 20 per 10° at 0.5° pixels, less the hole
        // (8 × 8) and the cut rows (10° to 12°: 4 rows of 20), plus the island (8 × 8).
        #expect(mask.tintedPixelCount == 20 * 20 - 8 * 8 - 4 * 20 + 8 * 8)
        // Visiting BB too: both, the shared border once.
        let both = CountryMask.build(shapes: shapes, visited: ["AA", "BB"], width: 720, height: 360)
        #expect(both.tintedPixelCount == mask.tintedPixelCount + 20 * 18)
    }

    @Test func aRingJumpingTheDateLineWrapsRound() {
        // An island from 170° E to 170° W written with its longitudes jumping across 180°.
        let island = AtlasShape(code: "DL", rings: [[at(10, 170), at(10, -170), at(20, -170), at(20, 170)]])
        let mask = CountryMask.build(shapes: [island], visited: ["DL"], width: 720, height: 360)
        for longitude in [170.25, 175, 179.99, -179.99, -175, -170.25] {
            #expect(mask.isTinted(at(15, longitude)), "\(longitude)")
        }
        #expect(!mask.isTinted(at(15, 0)) && !mask.isTinted(at(15, 169.5)) && !mask.isTinted(at(15, -169.5)) && !mask.isTinted(at(25, 180)))
        #expect(mask.tintedPixelCount == 40 * 20)
        // The same island split at 180° as the atlas's rings are fills the same pixels.
        let split = AtlasShape(code: "DL", rings: [square(10, 170, 20, 180), square(10, -180, 20, -170)])
        #expect(CountryMask.build(shapes: [split], visited: ["DL"], width: 720, height: 360).pixels == mask.pixels)
    }

    @Test func brokenShapesAreLeftOut() {
        let shapes = [AtlasShape(code: "AA", rings: [[at(.nan, 0), at(10, 10), at(0, 10)], [at(1, 1), at(2, 2)], []]),
                      AtlasShape(code: "BB", rings: [square(-10, -10, 10, 10)])]
        let mask = CountryMask.build(shapes: shapes, visited: ["AA", "BB"], width: 0, height: -1)
        #expect(mask.width == 1 && mask.height == 1 && mask.pixels.count == 1)
        let normal = CountryMask.build(shapes: shapes, visited: ["AA", "BB"], width: 360, height: 180)
        #expect(normal.tintedPixelCount == 20 * 20)
        #expect(!normal.isTinted(GeoCoordinate(latitude: .nan, longitude: 0)))
        #expect(CountryMask.build(shapes: [], visited: ["AA"]).tintedPixelCount == 0)
    }

    @Test func mipmapsAverageTheMask() {
        let shapes = [AtlasShape(code: "AA", rings: [square(0, 0, 45, 90)])]
        let mask = CountryMask.build(shapes: shapes, visited: ["AA"], width: 64, height: 32)
        let levels = mask.mipmaps(levels: 7)
        #expect(levels.map(\.width) == [64, 32, 16, 8, 4, 2, 1] && levels.map(\.height) == [32, 16, 8, 4, 2, 1, 1])
        #expect(levels[0].pixels == mask.pixels)
        for (upper, lower) in zip(levels, levels.dropFirst()) {
            #expect(lower.pixels.count == lower.width * lower.height)
            let column = lower.width / 2, row = 0
            let sources = [(2 * column, 2 * row), (2 * column + 1, 2 * row), (2 * column, 2 * row + 1), (2 * column + 1, 2 * row + 1)]
                .filter { $0.0 < upper.width && $0.1 < upper.height }
            let mean = sources.reduce(0) { $0 + Int(upper.pixels[$1.1 * upper.width + $1.0]) }
            #expect(Int(lower.pixels[row * lower.width + column]) == (mean + sources.count / 2) / sources.count)
        }
        // A sixteenth of the map is tinted, so the last level is a sixteenth of white.
        #expect(abs(Int(levels[6].pixels[0]) - 16) <= 1)
        #expect(mask.mipmaps(levels: 0).count == 1)
        // A 2048 × 1024 texture has 12 levels down to 1 × 1.
        let full = CountryMask(width: 2_048, height: 1_024).mipmaps(levels: 12)
        #expect(full.last.map { $0.width == 1 && $0.height == 1 } == true)
    }
}

/// A failed expectation names the mask's size and tinted pixels, not its two million values.
extension CountryMask: CustomTestStringConvertible {
    public var testDescription: String { "CountryMask \(width) × \(height), \(tintedPixelCount) tinted" }
}
