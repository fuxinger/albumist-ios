import Foundation
import AlbumistCore

// The centre of a country for `CountryGeometryBuilder`: the pole of inaccessibility of its main
// land, searched on a plane. Apart from the areas, as the search brings its own geometry (points,
// edges, a queue of squares).

extension CountryGeometryBuilder {
    // MARK: Centre

    /// A ring of the search, on the plane of the projection.
    struct Point: Sendable {
        var x: Double
        var y: Double
    }

    /// What the searches for the middles cost: the squares whose distance to the edges was
    /// measured, and the edges measured for them. Counted, so a test holds the work down
    /// whatever the load of the machine (as `OfflineWorldMap.LookupWork`).
    struct SearchWork: Hashable, Sendable {
        var cells = 0
        var edges = 0
    }

    /// At most about this many corners per ring in the search for the centre: the coast of
    /// Russia's main land has 16,000 in the map, and the middle only has to be well inside. A
    /// corner kept is never farther than perimeter / `searchCorners` from those dropped: a few
    /// kilometres for most countries, more only for long and ragged coasts (Norway, Chile,
    /// Canada), whose middle lies hundreds of kilometres inland.
    static let searchCorners = 200.0

    /// The pole of inaccessibility of `rings[outer]`, the holes of its region within its reach
    /// kept out. The ring, thinned to about `searchCorners` corners, is laid out on the azimuthal
    /// equidistant projection around its own centroid, so a ring across the antimeridian or round
    /// a pole is one shape on it.
    static func poleOfInaccessibility(_ rings: [[GeoCoordinate]], outer: Int, holes: [Bool], work: inout SearchWork) -> GeoCoordinate {
        let step = perimeter(rings[outer]) / searchCorners
        let ring = thinned(rings[outer], step: step)
        guard let first = ring.first else { return rings[outer][0] }
        let projection = AzimuthalEquidistantProjection(center: GeoMath.centroid(ring) ?? first)
        func laidOut(_ ring: [GeoCoordinate]) -> [Point] {
            ring.map { c in
                let p = projection.project(c)
                return Point(x: p.x, y: p.y)
            }
        }
        let main = laidOut(ring)
        guard main.count >= 3 else { return first }
        let reach = main.reduce(0) { max($0, ($1.x * $1.x + $1.y * $1.y).squareRoot()) }
        var holeOutlines: [[Point]] = []
        for i in rings.indices where holes[i] && i != outer {
            // A hole of this ring lies within its reach; holes of far islands are left alone.
            guard let corner = rings[i].first, projection.project(corner).angle * GeoMath.earthRadiusMeters <= reach else { continue }
            let hole = laidOut(thinned(rings[i], step: step))
            if hole.count >= 3 { holeOutlines.append(hole) }
        }
        let best = poleOfInaccessibility(main, holes: holeOutlines, work: &work)
        return projection.unproject(x: best.x, y: best.y)
    }

    /// `ring` with each corner closer than `step` metres to the last one kept left out, and
    /// without corners on a pole: where the map's ring runs along a pole (Antarctica's, cut at
    /// 180°), those are one point of the globe and would cut a slit to the pole.
    static func thinned(_ ring: [GeoCoordinate], step: Double) -> [GeoCoordinate] {
        var kept: [GeoCoordinate] = []
        for c in ring where c.latitude < 89.999 && c.latitude > -89.999 {
            if let last = kept.last, flatDistance(last, c) < step { continue }
            kept.append(c)
        }
        return kept
    }

    /// The length of a ring's edges in metres, corners on a pole left out (see `thinned`).
    static func perimeter(_ ring: [GeoCoordinate]) -> Double {
        var length = 0.0
        var previous: GeoCoordinate?
        var first: GeoCoordinate?
        for c in ring where c.latitude < 89.999 && c.latitude > -89.999 {
            if let previous { length += flatDistance(previous, c) } else { first = c }
            previous = c
        }
        if let first, let previous { length += flatDistance(previous, first) }
        return length
    }

    /// The distance between neighbouring corners of a ring, measured flat around `a` (exact
    /// enough over the few kilometres between them); right across the antimeridian.
    static func flatDistance(_ a: GeoCoordinate, _ b: GeoCoordinate) -> Double {
        let dy = (b.latitude - a.latitude) * GeoMath.metersPerDegreeLatitude
        let dx = MapHome.normalizedLongitude(b.longitude - a.longitude) * GeoMath.metersPerDegreeLatitude * cos(a.latitude * .pi / 180)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// One square of the search: its middle, half its side, the middle's signed distance to the
    /// polygon's edges (negative outside) and the most any point of the square can have.
    private struct Cell {
        var x: Double
        var y: Double
        var half: Double
        var distance: Double
        var potential: Double { distance + half * 2.0.squareRoot() }
    }

    /// The point inside `outer` and outside every hole that lies farthest from all their edges,
    /// within 1/64 of the polygon's size (coarse: the middle only has to be well inside, and the
    /// search is the most of the work): Mapbox's polylabel (V. Agafonkin, 2016). Squares covering
    /// the polygon are split, most promising first, while one could still hold a point farther
    /// inside than the best found by more than that. Deterministic: squares of equal promise are
    /// split in the order they were made. Bounded at `maximumCells` squares.
    static func poleOfInaccessibility(_ outer: [Point], holes: [[Point]], work: inout SearchWork) -> Point {
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for p in outer {
            minX = min(minX, p.x); minY = min(minY, p.y); maxX = max(maxX, p.x); maxY = max(maxY, p.y)
        }
        let width = maxX - minX, height = maxY - minY
        // Squares as wide as the polygon's narrow side, but at most 64 along its long side (a
        // sliver of a ring would otherwise need thousands).
        let side = max(min(width, height), max(width, height) / 64)
        guard side > 0, side.isFinite else { return outer[0] }
        let precision = max(width, height) / 64
        let edges = Edge.all(outer: outer, holes: holes)
        func cell(_ x: Double, _ y: Double, _ half: Double) -> Cell {
            work.cells += 1
            work.edges += edges.count
            return Cell(x: x, y: y, half: half, distance: signedDistance(Point(x: x, y: y), edges: edges))
        }
        var queue = CellQueue()
        var x = minX
        while x < maxX {
            var y = minY
            while y < maxY {
                queue.push(cell(x + side / 2, y + side / 2, side / 2))
                y += side
            }
            x += side
        }
        // A first guess: the ring's own centroid, else the middle of its box.
        var best = cell(minX + width / 2, minY + height / 2, 0)
        if let c = centroid(outer) {
            let guess = cell(c.x, c.y, 0)
            if guess.distance > best.distance { best = guess }
        }
        var cells = 0
        while let current = queue.pop(), cells < maximumCells {
            cells += 1
            if current.distance > best.distance { best = current }
            guard current.potential - best.distance > precision else { continue }
            let half = current.half / 2
            queue.push(cell(current.x - half, current.y - half, half))
            queue.push(cell(current.x + half, current.y - half, half))
            queue.push(cell(current.x - half, current.y + half, half))
            queue.push(cell(current.x + half, current.y + half, half))
        }
        return Point(x: best.x, y: best.y)
    }

    /// Squares one search looks at, at most (a guard against a pathological ring): the map's
    /// countries need about 70 on average and never more than a few hundred.
    static let maximumCells = 20_000

    /// An edge of the polygon of a search, from (`x`, `y`) to (`x + dx`, `endY`), with what every
    /// distance to it needs.
    struct Edge: Sendable {
        var x: Double
        var y: Double
        /// The end's own `y` (not `y + dy`, which can differ in the last bit from where the next
        /// edge starts and miscount a crossing there).
        var endY: Double
        var dx: Double
        var dy: Double
        var lengthSquared: Double
        /// An edge of the outer ring, else of a hole.
        var isOuter: Bool

        static func all(outer: [Point], holes: [[Point]]) -> [Edge] {
            var edges: [Edge] = []
            edges.reserveCapacity(holes.reduce(outer.count) { $0 + $1.count })
            for (ring, isOuter) in [(outer, true)] + holes.map({ ($0, false) }) {
                var a = ring[ring.count - 1]
                for b in ring {
                    let dx = b.x - a.x, dy = b.y - a.y
                    edges.append(Edge(x: a.x, y: a.y, endY: b.y, dx: dx, dy: dy, lengthSquared: dx * dx + dy * dy, isOuter: isOuter))
                    a = b
                }
            }
            return edges
        }
    }

    /// The distance from `p` to the nearest edge, negative when `p` is not inside the outer ring
    /// or is inside a hole (each by the even-odd rule, as the map reads its rings).
    static func signedDistance(_ p: Point, edges: [Edge]) -> Double {
        var nearest = Double.infinity
        var insideOuter = false, insideHole = false
        // The innermost loop of the search: plain comparisons rather than `min` and `max`, which
        // an unoptimised (test) build calls as generic functions.
        for e in edges {
            // A ray from `p` to the east crosses the edge.
            if (e.y > p.y) != (e.endY > p.y), p.x < e.dx * (p.y - e.y) / e.dy + e.x {
                if e.isOuter { insideOuter.toggle() } else { insideHole.toggle() }
            }
            var t = e.lengthSquared > 0 ? ((p.x - e.x) * e.dx + (p.y - e.y) * e.dy) / e.lengthSquared : 0
            if t < 0 { t = 0 } else if t > 1 { t = 1 }
            let ex = e.x + t * e.dx - p.x, ey = e.y + t * e.dy - p.y
            let d = ex * ex + ey * ey
            if d < nearest { nearest = d }
        }
        let d = nearest.squareRoot()
        return insideOuter && !insideHole ? d : -d
    }

    /// The area centroid of a ring on the plane; nil for a ring without area.
    static func centroid(_ ring: [Point]) -> Point? {
        var area = 0.0, cx = 0.0, cy = 0.0
        var a = ring[ring.count - 1]
        for b in ring {
            let f = a.x * b.y - b.x * a.y
            area += f
            cx += (a.x + b.x) * f
            cy += (a.y + b.y) * f
            a = b
        }
        guard area != 0 else { return nil }
        return Point(x: cx / (3 * area), y: cy / (3 * area))
    }

    /// The squares still to look at, the most promising first (a binary heap); squares of equal
    /// promise in the order they were made.
    private struct CellQueue {
        private var heap: [(cell: Cell, order: Int)] = []
        private var made = 0

        mutating func push(_ cell: Cell) {
            heap.append((cell, made))
            made += 1
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard Self.before(heap[child], heap[parent]) else { break }
                heap.swapAt(child, parent)
                child = parent
            }
        }

        mutating func pop() -> Cell? {
            guard !heap.isEmpty else { return nil }
            heap.swapAt(0, heap.count - 1)
            let top = heap.removeLast()
            var parent = 0
            while true {
                let left = 2 * parent + 1, right = left + 1
                var first = parent
                if left < heap.count, Self.before(heap[left], heap[first]) { first = left }
                if right < heap.count, Self.before(heap[right], heap[first]) { first = right }
                guard first != parent else { break }
                heap.swapAt(parent, first)
                parent = first
            }
            return top.cell
        }

        private static func before(_ a: (cell: Cell, order: Int), _ b: (cell: Cell, order: Int)) -> Bool {
            a.cell.potential != b.cell.potential ? a.cell.potential > b.cell.potential : a.order < b.order
        }
    }
}
