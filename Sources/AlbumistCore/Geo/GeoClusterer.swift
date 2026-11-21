import Foundation

/// Spatial hash index for radius queries on geographic points.
public struct GeoSpatialIndex<Element: Sendable>: Sendable {
    public struct Entry: Sendable {
        public let index: Int
        public let coordinate: GeoCoordinate
        public let element: Element
    }

    public let cellSize: Double
    private var cells: [GeoCell: [Int]] = [:]
    public private(set) var entries: [Entry] = []

    public init(cellSize: Double, points: [(GeoCoordinate, Element)]) {
        self.cellSize = cellSize
        entries.reserveCapacity(points.count)
        for (i, point) in points.enumerated() {
            entries.append(Entry(index: i, coordinate: point.0, element: point.1))
            cells[GeoCell(point.0, sizeMeters: cellSize), default: []].append(i)
        }
    }

    /// All entries within `radius` metres of `center` (radius must be ≤ cellSize).
    ///
    /// Every cell the circle can touch is read: per latitude band, the cells over the circle's
    /// widest longitude span (both sides of the antimeridian, all longitudes when the circle
    /// holds a pole). Sample points inside the circle missed cells far in the north and at the
    /// antimeridian, where a cell's span in degrees changes from band to band and a cell can be
    /// cut by ±180° (G1-01, review 18.11.2026).
    public func query(near center: GeoCoordinate, radius: Double) -> [Entry] {
        precondition(radius <= cellSize + 1e-6, "radius must not exceed the index cell size")
        // The circle on the sphere `GeoMath.distance` measures on, in degrees (a little more,
        // against rounding): every point within `radius` is at most this far in latitude.
        let reach = radius / GeoMath.earthRadiusMeters * 180 / .pi * (1 + 1e-9) + 1e-9
        let south = max(-90, center.latitude - reach), north = min(90, center.latitude + reach)
        // Widest longitude span of the circle; all longitudes when it holds a pole.
        let halfSpan: Double
        let cosLat = cos(center.latitude * .pi / 180)
        let sinReach = sin(radius / GeoMath.earthRadiusMeters)
        if north >= 90 || south <= -90 || sinReach >= cosLat {
            halfSpan = 180
        } else {
            halfSpan = min(180, asin(sinReach / cosLat) * 180 / .pi * (1 + 1e-9) + 1e-9)
        }
        let ranges = Self.longitudeRanges(from: center.longitude - halfSpan, to: center.longitude + halfSpan)
        let latStep = cellSize / GeoMath.metersPerDegreeLatitude
        var result: [Entry] = []
        for y in Int((south / latStep).rounded(.down))...Int((north / latStep).rounded(.down)) {
            // As `GeoCell` does: the longitude step of the band's middle.
            let bandLat = (Double(y) + 0.5) * latStep
            let lonStep = latStep / max(cos(bandLat * .pi / 180), 0.01)
            var visited = Set<Int>()
            for range in ranges {
                for x in Int((range.lowerBound / lonStep).rounded(.down))...Int((range.upperBound / lonStep).rounded(.down)) {
                    guard visited.insert(x).inserted, let indices = cells[GeoCell(x: x, y: y, sizeMeters: cellSize)] else { continue }
                    for i in indices where GeoMath.distance(entries[i].coordinate, center) <= radius {
                        result.append(entries[i])
                    }
                }
            }
        }
        return result
    }

    /// `from...to` in longitudes as stored (-180...180): split in two at the antimeridian.
    static func longitudeRanges(from: Double, to: Double) -> [ClosedRange<Double>] {
        if to - from >= 360 { return [-180...180] }
        if from < -180 { return [(from + 360)...180, -180...to] }
        if to > 180 { return [from...180, -180...(to - 360)] }
        return [from...to]
    }
}

/// Density-based clustering (DBSCAN) on geographic points.
///
/// Points are bucketed into a 3-D grid on the earth's surface (cube edge ε/1.8), so all points
/// in one cube are within ε of each other. That makes the algorithm close to linear even when
/// thousands of photos were taken at the same spot (home): a full cube is core at once, cubes
/// are connected with one matching pair, and only sparse points need individual distance
/// checks. The result is the classic DBSCAN result: same clusters, cluster order (by the
/// lowest index of a core point), border points go to the first cluster that reaches them.
public struct GeoClusterer: Sendable {
    public struct Cluster: Sendable, Hashable {
        public var memberIndices: [Int]
        public var centroid: GeoCoordinate
        /// 90th percentile distance of members to the centroid, in metres.
        public var radius90: Double
    }

    public var epsilonMeters: Double
    public var minPoints: Int

    public init(epsilonMeters: Double, minPoints: Int) {
        self.epsilonMeters = epsilonMeters
        self.minPoints = max(1, minPoints)
    }

    private struct CubeKey: Hashable {
        var x: Int, y: Int, z: Int
    }

    /// Returns clusters (sorted by size, descending) and indices of noise points.
    public func cluster(_ coordinates: [GeoCoordinate]) -> (clusters: [Cluster], noise: [Int]) {
        var distances = 0
        return cluster(coordinates, distances: &distances)
    }

    /// `cluster(_:)`, adding to `distances` the surface distances it computed between two points:
    /// the work that grows with the square of a group's size if a shortcut is lost (tests count
    /// it instead of timing it; review P5-14 b).
    func cluster(_ coordinates: [GeoCoordinate], distances: inout Int) -> (clusters: [Cluster], noise: [Int]) {
        var computed = 0
        defer { distances += computed }
        let n = coordinates.count
        guard n > 0 else { return ([], []) }
        let eps = epsilonMeters
        let side = eps / 1.8 // cube diagonal = 0.96 ε
        let reach = 2        // ⌈ε / side⌉

        // 1. Bucket points into cubes (positions on a sphere with the haversine radius).
        var cubeOf = [Int](repeating: 0, count: n)
        var keys: [CubeKey] = []
        var members: [[Int]] = []
        var cubeIndex: [CubeKey: Int] = [:]
        // Positions in space (metres). The straight distance between two of them is never
        // more than the distance on the surface, so "further apart than ε in space" safely
        // rules a pair out; the final test is always the surface distance.
        var position = [SIMD3<Double>](repeating: .zero, count: n)
        for (i, c) in coordinates.enumerated() {
            let lat = c.latitude * .pi / 180, lon = c.longitude * .pi / 180
            let r = GeoMath.earthRadiusMeters
            let p = SIMD3(r * cos(lat) * cos(lon), r * cos(lat) * sin(lon), r * sin(lat))
            position[i] = p
            let key = CubeKey(
                x: Int((p.x / side).rounded(.down)),
                y: Int((p.y / side).rounded(.down)),
                z: Int((p.z / side).rounded(.down))
            )
            if let existing = cubeIndex[key] {
                members[existing].append(i)
                cubeOf[i] = existing
            } else {
                cubeIndex[key] = keys.count
                cubeOf[i] = keys.count
                keys.append(key)
                members.append([i])
            }
        }
        // Occupied neighbour cubes (within reach), computed once per cube.
        var neighbourCubes = [[Int]](repeating: [], count: keys.count)
        for (cube, key) in keys.enumerated() {
            for dx in -reach...reach {
                for dy in -reach...reach {
                    for dz in -reach...reach where dx != 0 || dy != 0 || dz != 0 {
                        if let other = cubeIndex[CubeKey(x: key.x + dx, y: key.y + dy, z: key.z + dz)] {
                            neighbourCubes[cube].append(other)
                        }
                    }
                }
            }
        }
        func near(_ i: Int, _ j: Int) -> Bool {
            computed += 1
            return GeoMath.distance(coordinates[i], coordinates[j]) <= eps
        }
        // Bounding box of each cube's points: a neighbour cube whose box is further than ε
        // from a point (or another box) cannot hold a point within ε of it.
        let boxes = members.map { Box(position, $0) }
        let reachable = eps + 0.01 // a centimetre of slack against rounding in the bounds

        // 2. Core points: at least `minPoints` points (itself included) within ε.
        var isCore = [Bool](repeating: false, count: n)
        for cube in keys.indices {
            let own = members[cube]
            if own.count >= minPoints {
                for i in own { isCore[i] = true }
                continue
            }
            for i in own {
                var count = 0
                for j in own where near(i, j) { count += 1 }
                if count < minPoints {
                    search: for other in neighbourCubes[cube] where boxes[other].distance(to: position[i]) <= reachable {
                        for j in members[other] where near(i, j) {
                            count += 1
                            if count >= minPoints { break search }
                        }
                    }
                }
                isCore[i] = count >= minPoints
            }
        }

        // 3. Connect core points (union-find): a cube's core points are connected anyway,
        //    two cubes are connected as soon as one pair of their core points is within ε.
        var parent = Array(0..<n)
        func find(_ i: Int) -> Int {
            var root = i
            while parent[root] != root { root = parent[root] }
            var node = i
            while parent[node] != root { let next = parent[node]; parent[node] = root; node = next }
            return root
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
        }
        var coreMembers = [[Int]](repeating: [], count: keys.count)
        for cube in keys.indices {
            coreMembers[cube] = members[cube].filter { isCore[$0] }
            if let first = coreMembers[cube].first {
                for i in coreMembers[cube].dropFirst() { union(first, i) }
            }
        }
        let coreBoxes = coreMembers.map { Box(position, $0) }
        for cube in keys.indices {
            guard let a = coreMembers[cube].first else { continue }
            for other in neighbourCubes[cube] where other > cube {
                guard let b = coreMembers[other].first, find(a) != find(b),
                      coreBoxes[cube].distance(to: coreBoxes[other]) <= reachable else { continue }
                if let (i, j) = Self.firstPairWithin(reachable, coreMembers[cube], coreMembers[other], position, near) {
                    union(i, j)
                }
            }
        }

        // 4. Cluster ids in order of each cluster's lowest core index (the DBSCAN seed order).
        var clusterOfRoot: [Int: Int] = [:]
        var labels = [Int](repeating: -1, count: n)
        for i in 0..<n where isCore[i] {
            let root = find(i)
            if let id = clusterOfRoot[root] {
                labels[i] = id
            } else {
                labels[i] = clusterOfRoot.count
                clusterOfRoot[root] = labels[i]
            }
        }
        let clusterCount = clusterOfRoot.count

        // 5. Border points join the first cluster (lowest id) with a core point within ε.
        for i in 0..<n where !isCore[i] {
            let cube = cubeOf[i]
            var best = Int.max
            for other in [cube] + neighbourCubes[cube] where coreBoxes[other].distance(to: position[i]) <= reachable {
                for j in coreMembers[other] where labels[j] < best && near(i, j) { best = labels[j] }
            }
            if best != Int.max { labels[i] = best }
        }

        var clusterMembers = [[Int]](repeating: [], count: clusterCount)
        var noise: [Int] = []
        for (i, label) in labels.enumerated() {
            if label >= 0 { clusterMembers[label].append(i) } else { noise.append(i) }
        }
        let clusters = clusterMembers.compactMap { indices -> Cluster? in
            guard let centroid = GeoMath.centroid(indices.map { coordinates[$0] }) else { return nil }
            let distances = indices.map { GeoMath.distance(coordinates[$0], centroid) }.sorted()
            let p90 = distances.isEmpty ? 0 : distances[min(distances.count - 1, Int(Double(distances.count) * 0.9))]
            return Cluster(memberIndices: indices, centroid: centroid, radius90: p90)
        }
        .sorted { $0.memberIndices.count > $1.memberIndices.count }
        return (clusters, noise)
    }

    /// Axis-aligned box around some points in space.
    private struct Box {
        var lo = SIMD3<Double>(repeating: .infinity)
        var hi = SIMD3<Double>(repeating: -.infinity)

        init(_ position: [SIMD3<Double>], _ indices: [Int]) {
            for i in indices {
                lo = pointwiseMin(lo, position[i])
                hi = pointwiseMax(hi, position[i])
            }
        }

        var isEmpty: Bool { lo.x > hi.x }
        var center: SIMD3<Double> { (lo + hi) / 2 }

        func distance(to p: SIMD3<Double>) -> Double {
            guard !isEmpty else { return .infinity }
            let gap = pointwiseMax(pointwiseMax(lo - p, p - hi), .zero)
            return (gap * gap).sum().squareRoot()
        }

        func distance(to other: Box) -> Double {
            guard !isEmpty, !other.isEmpty else { return .infinity }
            let gap = pointwiseMax(pointwiseMax(lo - other.hi, other.lo - hi), .zero)
            return (gap * gap).sum().squareRoot()
        }
    }

    /// Some pair (one point from each list) within ε, or nil. Points are compared only when
    /// their positions along the line between the two groups differ by at most ε (a lower
    /// bound of their distance), so two dense groups just over ε apart cost a sort, not a
    /// comparison of every pair.
    private static func firstPairWithin(
        _ eps: Double, _ a: [Int], _ b: [Int], _ position: [SIMD3<Double>], _ near: (Int, Int) -> Bool
    ) -> (Int, Int)? {
        let (outer, inner) = a.count <= b.count ? (a, b) : (b, a)
        var axis = Box(position, inner).center - Box(position, outer).center
        let length = (axis * axis).sum().squareRoot()
        axis = length > 0 ? axis / length : SIMD3(1, 0, 0)
        let sorted = inner.map { ((position[$0] * axis).sum(), $0) }.sorted { $0.0 < $1.0 }
        for i in outer {
            let t = (position[i] * axis).sum()
            // First entry with t_j ≥ t − ε.
            var low = 0, high = sorted.count
            while low < high {
                let mid = (low + high) / 2
                if sorted[mid].0 < t - eps { low = mid + 1 } else { high = mid }
            }
            var k = low
            while k < sorted.count, sorted[k].0 <= t + eps {
                let j = sorted[k].1
                if near(i, j) { return a.count <= b.count ? (i, j) : (j, i) }
                k += 1
            }
        }
        return nil
    }
}
