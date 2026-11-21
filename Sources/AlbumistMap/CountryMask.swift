import Foundation
import AlbumistCore

/// The visited countries as an image wrapped round our own globe (concept §4.2: "Besuchte Länder
/// sind leicht aufgehellt"), from the travel atlas's shapes (`AtlasShapes.make`): an 8-bit mask,
/// equirectangular like the Earth image (column 0 starts at −180°, row 0 at 90° N; u = (lon + 180)
/// / 360, v = (90 − lat) / 180), 255 where the globe brightens the Earth, 0 elsewhere. The GPU
/// samples it with linear filtering, so its edges come out soft.
///
/// The fill follows the atlas exactly (`AtlasShapes.filledCode`): a pixel is tinted when its
/// centre lies in a visited country's shape (even-odd over the shape's rings, as the atlas draws
/// and `AtlasShape.contains` tests) and in none of the neutral shapes of the disputed areas laid
/// over that country (decision 18.11.2026: a disputed area is never a side's country, so it is
/// cut out, never tinted). Shapes without a code (disputed areas the map draws as countries) are
/// never tinted.
///
/// Built with a scanline fill: each shape's edges go into an edge table sorted by their first
/// row, a sweep down the rows keeps the active edges and pairs their crossings into spans, and a
/// country's spans lose those of the disputed areas over it before they are written. The work
/// grows with the edges and the rows they cross, not with rows × points (`Work`): the whole world
/// visited (about 21,000 edges) took 0.2 s in an unoptimized build on a desktop computer, so the
/// app builds it off the main thread. Rings that jump across the antimeridian (a step of
/// more than 180° in longitude) are unwrapped and their spans wrapped round, so an island on the
/// date line fills right; the atlas's own rings are already split at ±180°.
public struct CountryMask: Hashable, Sendable {
    public static let defaultWidth = 2_048
    public static let defaultHeight = 1_024

    public let width: Int
    public let height: Int
    /// Row by row from the north, `width` per row.
    public private(set) var pixels: [UInt8]
    /// What the build did.
    public private(set) var work: Work

    /// The effort of a build: edges put into edge tables, rows swept, crossings computed, pixels
    /// written. A test keeps it about linear in the map's size.
    public struct Work: Hashable, Sendable {
        public var edges = 0
        public var rows = 0
        public var crossings = 0
        public var pixelsWritten = 0
    }

    /// An empty mask (nothing tinted).
    public init(width: Int = defaultWidth, height: Int = defaultHeight) {
        self.width = max(width, 1)
        self.height = max(height, 1)
        pixels = [UInt8](repeating: 0, count: self.width * self.height)
        work = Work()
    }

    /// The mask of the `visited` country codes over `shapes`.
    public static func build(shapes: [AtlasShape], visited: Set<String>, width: Int = defaultWidth, height: Int = defaultHeight) -> CountryMask {
        var mask = CountryMask(width: width, height: height)
        let raster = Raster(width: mask.width, height: mask.height)
        var work = Work()
        // The spans of each neutral shape, made once even when it lies over two visited countries.
        var cutters: [Int: Spans] = [:]
        for shape in shapes where !shape.isNeutral && !shape.code.isEmpty && visited.contains(shape.code) {
            var spans = raster.spans(of: shape.rings, work: &work)
            guard !spans.isEmpty else { continue }
            for (index, area) in shapes.enumerated() where area.neutralOver.contains(shape.code) {
                if cutters[index] == nil { cutters[index] = raster.spans(of: area.rings, work: &work) }
                if let cut = cutters[index] { spans.subtract(cut) }
            }
            mask.write(spans, work: &work)
        }
        mask.work = work
        return mask
    }

    /// The value at a pixel; 0 outside the image.
    public func value(column: Int, row: Int) -> UInt8 {
        guard column >= 0, column < width, row >= 0, row < height else { return 0 }
        return pixels[row * width + column]
    }

    /// The pixel holding `coordinate` (longitudes wrap round, latitudes beyond the poles clamp).
    public func pixel(of coordinate: GeoCoordinate) -> (column: Int, row: Int)? {
        guard coordinate.latitude.isFinite, coordinate.longitude.isFinite else { return nil }
        let u = (MapHome.normalizedLongitude(coordinate.longitude) + 180) / 360
        let v = (90 - min(max(coordinate.latitude, -90), 90)) / 180
        return (min(Int(u * Double(width)), width - 1), min(Int(v * Double(height)), height - 1))
    }

    /// Whether the pixel holding `coordinate` is tinted.
    public func isTinted(_ coordinate: GeoCoordinate) -> Bool {
        guard let pixel = pixel(of: coordinate) else { return false }
        return value(column: pixel.column, row: pixel.row) > 0
    }

    /// The coordinate of a pixel's centre: what the fill tests.
    public static func center(column: Int, row: Int, width: Int, height: Int) -> GeoCoordinate {
        GeoCoordinate(latitude: Raster.centerLatitude(row, height: height), longitude: Raster.centerLongitude(column, width: width))
    }

    public var tintedPixelCount: Int { pixels.reduce(0) { $0 + ($1 > 0 ? 1 : 0) } }

    /// The mask and its smaller levels for a mipmapped texture: each level half the size of the
    /// one before (at least 1), each pixel the rounded mean of the 2 × 2 (or fewer, at an odd
    /// edge) pixels above it; `levels` of them, at least 1.
    public func mipmaps(levels: Int) -> [Level] {
        var result = [Level(width: width, height: height, pixels: pixels)]
        while result.count < max(levels, 1) {
            result.append(result[result.count - 1].halved())
        }
        return result
    }

    /// One level of the mask's mipmaps.
    public struct Level: Hashable, Sendable {
        public var width: Int
        public var height: Int
        /// Row by row from the north, `width` per row.
        public var pixels: [UInt8]

        public init(width: Int, height: Int, pixels: [UInt8]) {
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        func halved() -> Level {
            let w = max(1, width / 2), h = max(1, height / 2)
            var out = [UInt8](repeating: 0, count: w * h)
            for row in 0..<h {
                let rows = (2 * row)..<min(2 * row + 2, height)
                for column in 0..<w {
                    let columns = (2 * column)..<min(2 * column + 2, width)
                    var sum = 0, n = 0
                    for r in rows {
                        for c in columns {
                            sum += Int(pixels[r * width + c])
                            n += 1
                        }
                    }
                    out[row * w + column] = UInt8((sum + n / 2) / max(n, 1))
                }
            }
            return Level(width: w, height: h, pixels: out)
        }
    }

    private mutating func write(_ spans: Spans, work: inout Work) {
        for (offset, row) in spans.rows.enumerated() {
            let y = spans.firstRow + offset
            for span in row {
                let start = y * width
                for x in span.lowerBound..<span.upperBound { pixels[start + x] = 255 }
                work.pixelsWritten += span.count
            }
        }
    }
}

/// The spans of a shape, row by row from `firstRow`: sorted, apart from each other, within the
/// image's columns.
struct Spans: Sendable {
    var firstRow: Int
    var rows: [[Range<Int>]]

    var isEmpty: Bool { rows.allSatisfy(\.isEmpty) }

    /// Takes out every column `other` covers.
    mutating func subtract(_ other: Spans) {
        for (offset, cut) in other.rows.enumerated() where !cut.isEmpty {
            let index = other.firstRow + offset - firstRow
            guard index >= 0, index < rows.count, !rows[index].isEmpty else { continue }
            rows[index] = Self.subtract(cut, from: rows[index])
        }
    }

    /// `spans` without `cut` (both sorted and disjoint): one pass over both.
    static func subtract(_ cut: [Range<Int>], from spans: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var j = 0
        for span in spans {
            var start = span.lowerBound
            let end = span.upperBound
            while j < cut.count, cut[j].upperBound <= start { j += 1 }
            var k = j
            while k < cut.count, cut[k].lowerBound < end, start < end {
                if cut[k].lowerBound > start { result.append(start..<cut[k].lowerBound) }
                start = max(start, cut[k].upperBound)
                k += 1
            }
            if start < end { result.append(start..<end) }
        }
        return result
    }
}

/// The scanline fill of `CountryMask` on a grid of `width` × `height` pixel centres.
struct Raster: Sendable {
    let width: Int
    let height: Int

    static func centerLongitude(_ column: Int, width: Int) -> Double { (Double(column) + 0.5) * 360 / Double(width) - 180 }
    static func centerLatitude(_ row: Int, height: Int) -> Double { 90 - (Double(row) + 0.5) * 180 / Double(height) }

    func longitude(_ column: Int) -> Double { Self.centerLongitude(column, width: width) }
    func latitude(_ row: Int) -> Double { Self.centerLatitude(row, height: height) }

    /// An edge of a ring as `AtlasShape.contains` takes it: `a` the ring's point, `b` the one
    /// before it, and the rows whose centre latitude φ it crosses (min ≤ φ < max of its ends).
    struct Edge {
        var firstRow: Int
        var lastRow: Int
        var aLatitude: Double
        var aLongitude: Double
        var bLatitude: Double
        var bLongitude: Double

        /// The longitude where the edge crosses latitude `phi`: the very expression of
        /// `AtlasShape.contains`, so a pixel centre is inside exactly when that test says so.
        func longitude(at phi: Double) -> Double {
            (bLongitude - aLongitude) * (phi - aLatitude) / (bLatitude - aLatitude) + aLongitude
        }
    }

    /// The rows whose centre latitude lies in [`low`, `high`), or nil.
    func rows(from low: Double, to high: Double) -> ClosedRange<Int>? {
        guard low < high else { return nil }
        let scale = Double(height) / 180
        var first = Int(((90 - high) * scale - 0.5).rounded(.down)) + 1
        first = min(max(first, 0), height)
        while first > 0, latitude(first - 1) < high { first -= 1 }
        while first < height, !(latitude(first) < high) { first += 1 }
        var last = Int(((90 - low) * scale - 0.5).rounded(.down))
        last = min(max(last, -1), height - 1)
        while last + 1 < height, latitude(last + 1) >= low { last += 1 }
        while last >= 0, !(latitude(last) >= low) { last -= 1 }
        return first <= last ? first...last : nil
    }

    /// The first column whose centre is at or east of `x` (degrees, unwrapped values allowed:
    /// columns below 0 or from `width` on belong to the neighbouring turns of the Earth).
    func boundary(_ x: Double) -> Int {
        var b = Int(((x + 180) * Double(width) / 360 - 0.5).rounded(.up))
        while longitude(b - 1) >= x { b -= 1 }
        while longitude(b) < x { b += 1 }
        return b
    }

    /// The spans inside the rings, even-odd over all of them.
    func spans(of rings: [[GeoCoordinate]], work: inout CountryMask.Work) -> Spans {
        let table = edgeTable(of: rings, work: &work)
        let edges = table.edges, wrappedEdges = table.wrapped
        var firstRow = Int.max, lastRow = Int.min
        for edge in edges {
            firstRow = min(firstRow, edge.firstRow)
            lastRow = max(lastRow, edge.lastRow)
        }
        for edge in wrappedEdges.joined() {
            firstRow = min(firstRow, edge.firstRow)
            lastRow = max(lastRow, edge.lastRow)
        }
        guard firstRow <= lastRow else { return Spans(firstRow: 0, rows: []) }

        var rows: [[Range<Int>]] = []
        rows.reserveCapacity(lastRow - firstRow + 1)
        var active: [Edge] = []
        var next = 0
        var toggles: [Int] = []
        for row in firstRow...lastRow {
            work.rows += 1
            let phi = latitude(row)
            while next < edges.count, edges[next].firstRow <= row {
                active.append(edges[next])
                next += 1
            }
            active.removeAll { $0.lastRow < row }
            toggles.removeAll(keepingCapacity: true)
            for edge in active {
                toggles.append(min(max(boundary(edge.longitude(at: phi)), 0), width))
            }
            work.crossings += active.count
            for ringEdges in wrappedEdges {
                addCrossings(of: ringEdges, row: row, to: &toggles, work: &work)
            }
            toggles.sort()
            rows.append(Self.spans(between: toggles))
        }
        return Spans(firstRow: firstRow, rows: rows)
    }

    /// The edges of the rings: those of a ring across the antimeridian unwrapped (`unwrapped`),
    /// one list per ring; all others in one table, by their first row.
    private func edgeTable(of rings: [[GeoCoordinate]], work: inout CountryMask.Work) -> (edges: [Edge], wrapped: [[Edge]]) {
        var edges: [Edge] = []
        var wrapped: [[GeoCoordinate]] = []
        for ring in rings where ring.count >= 3 {
            guard ring.allSatisfy({ $0.latitude.isFinite && $0.longitude.isFinite }) else { continue }
            var jumps = false
            var previous = ring[ring.count - 1]
            for point in ring {
                if abs(point.longitude - previous.longitude) > 180 { jumps = true }
                previous = point
            }
            if jumps {
                wrapped.append(Self.unwrapped(ring))
            } else {
                appendEdges(of: ring, to: &edges)
            }
        }
        work.edges += edges.count
        // The edge table: edges by their first row.
        edges.sort { $0.firstRow < $1.firstRow }
        var wrappedEdges: [[Edge]] = []
        for ring in wrapped {
            var ringEdges: [Edge] = []
            appendEdges(of: ring, to: &ringEdges)
            work.edges += ringEdges.count
            wrappedEdges.append(ringEdges)
        }
        return (edges, wrappedEdges)
    }

    /// The toggles of one unwrapped ring's edges in `row`: its crossings of the row's centre in
    /// pairs, each pair wrapped onto the raster (`addWrapped`).
    private func addCrossings(of ringEdges: [Edge], row: Int, to toggles: inout [Int], work: inout CountryMask.Work) {
        let phi = latitude(row)
        var crossings: [Double] = []
        for edge in ringEdges where edge.firstRow <= row && row <= edge.lastRow {
            crossings.append(edge.longitude(at: phi))
        }
        work.crossings += crossings.count
        crossings.sort()
        var i = 0
        while i + 1 < crossings.count {
            addWrapped(boundary(crossings[i]), boundary(crossings[i + 1]), to: &toggles)
            i += 2
        }
    }

    /// The spans between sorted toggles, taken in pairs; an empty pair adds none.
    private static func spans(between toggles: [Int]) -> [Range<Int>] {
        var spans: [Range<Int>] = []
        var i = 0
        while i + 1 < toggles.count {
            if toggles[i] < toggles[i + 1] {
                // Touching spans merge into one.
                if let last = spans.last, last.upperBound == toggles[i] {
                    spans[spans.count - 1] = last.lowerBound..<toggles[i + 1]
                } else {
                    spans.append(toggles[i]..<toggles[i + 1])
                }
            }
            i += 2
        }
        return spans
    }

    /// The edges of a ring that cross a row centre, `a` the point and `b` the one before it.
    private func appendEdges(of ring: [GeoCoordinate], to edges: inout [Edge]) {
        var b = ring[ring.count - 1]
        for a in ring {
            defer { b = a }
            guard a.latitude != b.latitude,
                  let rows = rows(from: min(a.latitude, b.latitude), to: max(a.latitude, b.latitude)) else { continue }
            edges.append(Edge(firstRow: rows.lowerBound, lastRow: rows.upperBound, aLatitude: a.latitude, aLongitude: a.longitude,
                              bLatitude: b.latitude, bLongitude: b.longitude))
        }
    }

    /// Toggles for the columns [`start`, `end`) of an unwrapped span, wrapped into the image.
    private func addWrapped(_ start: Int, _ end: Int, to toggles: inout [Int]) {
        guard start < end else { return }
        if end - start >= width {
            toggles += [0, width]
            return
        }
        let shift = Int((Double(start) / Double(width)).rounded(.down)) * width
        let s = start - shift, e = end - shift
        if e <= width {
            toggles += [s, e]
        } else {
            toggles += [s, width, 0, e - width]
        }
    }

    /// The ring with each longitude moved by whole turns to within 180° of the one before, so
    /// its edges no longer jump across the antimeridian.
    static func unwrapped(_ ring: [GeoCoordinate]) -> [GeoCoordinate] {
        var result: [GeoCoordinate] = []
        result.reserveCapacity(ring.count)
        for point in ring {
            guard let last = result.last else {
                result.append(point)
                continue
            }
            var longitude = point.longitude
            while longitude - last.longitude > 180 { longitude -= 360 }
            while longitude - last.longitude < -180 { longitude += 360 }
            result.append(GeoCoordinate(latitude: point.latitude, longitude: longitude))
        }
        return result
    }
}
