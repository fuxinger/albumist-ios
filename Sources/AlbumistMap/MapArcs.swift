import Foundation
import AlbumistCore

/// The arcs of the globe (concept §4.2): from the home of each trip's time to the trip's
/// destination, like Flighty. Trips from one home to the same destination share one arc, a little
/// stronger the more trips it carries. Only trips with a known home get one ("Kein Zuhause
/// bekannt: keine Bögen, nur Stecknadeln", concept §11). The home is the rounded one of the trip's
/// time, so after a move the trips start from the new home and get arcs of their own (concept §8,
/// "Frühere Wohnorte").
public enum MapArcs {
    /// Destinations this close are one destination ("Bögen zum selben Ziel werden ein Bogen",
    /// concept §4.2): a city and its airport, a town and the hotel outside it. The share images
    /// merge their arcs and points by the same distance (`MapShare.world`).
    public static let mergeMeters = 25_000.0

    /// Whether the globe shows the arcs in a view this wide on the ground: they start at the
    /// rounded home and vanish with the house below `MapHome.houseMinimumWidthMeters` (concept
    /// §8: "verschwinden unter 300 km Bildbreite zusammen mit dem Häuschen. So zeigen sie nie
    /// genauer auf den Wohnort als das Häuschen"); in the world view they stay. A width that is
    /// no number shows none.
    public static func areShown(atWidth meters: Double) -> Bool {
        meters >= MapHome.houseMinimumWidthMeters
    }

    /// The arcs of `trips`, at most `MapSummary.maxArcs` (concept §9): the strongest first, then
    /// the one with the most recent trip, then by id; that is also what is kept when there are
    /// more. An arc's years are its trips' years as the time travel counts them (the year of
    /// each trip's first local day, `MapYears.compute`).
    ///
    /// An arc's id is "arc:" and the id of the trip it ends at (the one leading its group): stable
    /// while that trip leads it, and nothing in it tells where home is, not even hashed (a hash
    /// of a rounded home can be undone by trying every cell of the grid).
    ///
    /// Trips are grouped greedily in `byLeadership` order (the most photos first): a trip joins
    /// the nearest arc from the same rounded home whose end lies within `mergeMeters` of its
    /// destination (a tie: the older arc), or starts a new arc that ends at its own destination.
    /// So an arc ends at the destination of its trip with the most photos, and every trip of it
    /// went to within `mergeMeters` of there: destinations a little apart never chain into one arc
    /// that ends far from some of its trips.
    public static func build(trips: [MapTrip]) -> [MapArc] {
        var homes: [String: Int] = [:]
        var destinations = Clusters(radiusMeters: mergeMeters)
        // One per leader of `destinations`, at the same index.
        var groups: [ArcGroup] = []
        for trip in byLeadership(trips) {
            let destination = trip.geometry.destination
            guard let home = trip.home, home.coordinate.isPlausible, destination.isPlausible else { continue }
            let key = homeKey(home.coordinate)
            let space: Int
            if let known = homes[key] {
                space = known
            } else {
                space = homes.count
                homes[key] = space
            }
            let member = ArcGroup.Member(id: trip.id, start: trip.geometry.start, year: trip.geometry.firstDay.year)
            let assignment = destinations.assign(destination, space: space)
            if assignment.isNew {
                groups.append(ArcGroup(id: "arc:\(trip.id.rawValue)", from: home.coordinate, to: destination, members: [member],
                                       newest: member.start))
            } else {
                groups[assignment.leader].members.append(member)
                groups[assignment.leader].newest = max(groups[assignment.leader].newest, member.start)
            }
        }
        // Stronger first, then the one with the more recent trip, then the smaller id ("the
        // strongest and newest are kept", `MapSummary.maxArcs`). Decided on small keys, and only
        // the arcs kept are made.
        let kept = groups.indices
            .map { (weight: groups[$0].members.count, newest: groups[$0].newest, id: groups[$0].id, index: $0) }
            .sorted { a, b in
                if a.weight != b.weight { return a.weight > b.weight }
                if a.newest != b.newest { return a.newest > b.newest }
                return a.id < b.id
            }
            .prefix(MapSummary.maxArcs)
        return kept.map { groups[$0.index].arc() }
    }

    /// `trips` in the order in which they lead groups (here and on the share images): the most
    /// photos first, then the earlier start, then the smaller id. So a group's arc or point is the
    /// destination of its trip with the most photos, and the same trips in any order give the
    /// same groups. A repeated id, which the summary never has, is kept once, at its first place
    /// in this order (the copy with the most photos).
    static func byLeadership(_ trips: [MapTrip]) -> [MapTrip] {
        // The keys are sorted, not the trips: moving whole trips (places, route) while sorting
        // costs more than all the rest for thousands of trips.
        let order = trips.indices
            .map { (photos: trips[$0].geometry.photoCount, start: trips[$0].geometry.start, id: trips[$0].id.rawValue, index: $0) }
            .sorted { a, b in
                if a.photos != b.photos { return a.photos > b.photos }
                if a.start != b.start { return a.start < b.start }
                return a.id < b.id
            }
        var seen = Set<String>()
        return order.compactMap { seen.insert($0.id).inserted ? trips[$0.index] : nil }
    }

    /// Whether `a` comes before `b` in `byLeadership` order: for picking one trip without sorting
    /// them all.
    static func leads(_ a: MapTrip, before b: MapTrip) -> Bool {
        if a.geometry.photoCount != b.geometry.photoCount { return a.geometry.photoCount > b.geometry.photoCount }
        if a.geometry.start != b.geometry.start { return a.geometry.start < b.geometry.start }
        return a.id.rawValue < b.id.rawValue
    }

    /// A rounded home as a key for keeping the arcs of different homes apart while they are
    /// grouped: its coordinate to 0.001° (about 100 m, far finer than the grid home is rounded
    /// to, so two homes never share a key). It is never stored: no id, log or report holds it.
    static func homeKey(_ home: GeoCoordinate) -> String {
        "\(Int((home.latitude * 1_000).rounded())),\(Int((home.longitude * 1_000).rounded()))"
    }
}

/// An arc while its trips are grouped.
private struct ArcGroup: Sendable {
    struct Member: Sendable {
        var id: AlbumistID
        var start: Date
        /// The trip's year (`TripGeometry.firstDay`).
        var year: Int
    }

    /// From the trip that leads the group (the one with the most photos, where the arc ends):
    /// stable while that trip leads it. A trip has one home, so no two groups share it.
    var id: String
    var from: GeoCoordinate
    var to: GeoCoordinate
    var members: [Member]
    /// The start of its most recent trip.
    var newest: Date

    func arc() -> MapArc {
        let members = members.sorted { ($0.start, $0.id.rawValue) < ($1.start, $1.id.rawValue) }
        // Sorted before removing repeats: across the date line a later trip can begin on an
        // earlier local day.
        var years: [Int] = []
        for year in members.map(\.year).sorted() where years.last != year {
            years.append(year)
        }
        return MapArc(id: id, from: from, to: to, tripIDs: members.map(\.id), years: years)
    }
}

extension MapArcs {
    /// Greedy leader clustering on the sphere, how destinations are merged (arcs here, arcs and
    /// points on the share images): a point joins the nearest leader within `radiusMeters` in its
    /// space (a tie: the older leader), else it leads a new cluster. Spaces keep apart what must
    /// never merge, such as arcs from different homes.
    ///
    /// Leaders are kept in cubes of `radiusMeters` over their position in 3D, so a point is
    /// measured only against the leaders of the 27 cubes around it: about linear for thousands of
    /// trips ("Tausende Tagesausflüge", concept §11) instead of every trip against every arc. And
    /// the search needs no special case at the antimeridian or the poles: two points within
    /// `radiusMeters` along the Earth are closer than that in a straight line, so their cubes are
    /// at most one apart on each axis.
    struct Clusters: Sendable {
        let radiusMeters: Double
        /// The first point of each cluster, in the order they came.
        private(set) var leaders: [GeoCoordinate] = []
        /// Distances measured so far: what keeps the work about linear, and what a test counts.
        private(set) var distancesMeasured = 0
        private var cubes: [Cube: [Int]] = [:]

        init(radiusMeters: Double) {
            self.radiusMeters = radiusMeters
        }

        /// Puts `point` (a plausible coordinate) into the cluster of the nearest leader within
        /// `radiusMeters` in `space`, or makes it a new leader.
        mutating func assign(_ point: GeoCoordinate, space: Int = 0) -> Assignment {
            guard let home = cube(point, space: space) else {
                // Not a place on Earth: near nothing, and never searched for.
                leaders.append(point)
                return Assignment(leader: leaders.count - 1, isNew: true)
            }
            var nearest: (meters: Double, leader: Int)?
            for dx in -1...1 {
                for dy in -1...1 {
                    for dz in -1...1 {
                        let around = Cube(space: space, x: home.x + dx, y: home.y + dy, z: home.z + dz)
                        for leader in cubes[around] ?? [] {
                            let meters = GeoMath.distance(point, leaders[leader])
                            distancesMeasured += 1
                            guard meters <= radiusMeters else { continue }
                            if let best = nearest, best <= (meters, leader) { continue }
                            nearest = (meters, leader)
                        }
                    }
                }
            }
            if let nearest { return Assignment(leader: nearest.leader, isNew: false) }
            leaders.append(point)
            cubes[home, default: []].append(leaders.count - 1)
            return Assignment(leader: leaders.count - 1, isNew: true)
        }

        /// The cube holding `point`: its unit vector divided by the radius as an angle, rounded
        /// down. `nil` for a coordinate that is not finite.
        private func cube(_ point: GeoCoordinate, space: Int) -> Cube? {
            guard point.latitude.isFinite, point.longitude.isFinite, radiusMeters > 0 else { return nil }
            let latitude = point.latitude * .pi / 180
            let longitude = point.longitude * .pi / 180
            let side = radiusMeters / GeoMath.earthRadiusMeters
            func index(_ value: Double) -> Int { Int((value / side).rounded(.down)) }
            return Cube(space: space, x: index(cos(latitude) * cos(longitude)), y: index(cos(latitude) * sin(longitude)), z: index(sin(latitude)))
        }
    }
}

extension MapArcs.Clusters {
    /// Where `assign` put a point.
    struct Assignment: Sendable {
        /// Into `leaders`.
        var leader: Int
        /// The point leads a new cluster.
        var isNew: Bool
    }

    /// A cube of `radiusMeters` in one space, where leaders are kept (`cube(_:space:)`).
    private struct Cube: Hashable, Sendable {
        var space: Int
        var x: Int
        var y: Int
        var z: Int
    }
}
