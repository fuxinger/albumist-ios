import Foundation
import AlbumistCore

// The places of `TripGeometryBuilder`: the day places (a day's photos close to each other), the
// trip places they merge into, and what each trip place shows (its name, point, covers and
// height).

extension TripGeometryBuilder {
    // MARK: Places

    /// Two points at most `TripGeometry.placeRadiusMeters` apart along the Earth (as
    /// `GeoMath.distance` measures, on the same sphere) are at most this apart in a straight line
    /// through it, squared (`UnitVector.chordSquared`): a test with no trigonometry, exact for
    /// short distances, right across the antimeridian and at the poles.
    static let placeChordSquared: Double = {
        let chord = 2 * sin(TripGeometry.placeRadiusMeters / GeoMath.earthRadiusMeters / 2)
        return chord * chord
    }()

    /// The day places, oldest first (by their first photo): per local day, the day's photos in
    /// time order, each joining the nearest group of that day whose running centre is within
    /// `TripGeometry.placeRadiusMeters`, else starting one; the groups with at least
    /// `TripGeometry.minimumPhotosPerPlace` photos. The running centre is the spherical mean of
    /// the group's photos so far, so a town walked across from one end to the other stays one
    /// place, and a group across the antimeridian or near a pole is no different.
    /// A day place's point is `GeoMath.dayPoint` of its photos in time order: a real photo
    /// location where most of them were, at a bounded cost.
    ///
    /// A photo is compared with every group of its day: the groups of a day lie 3 km apart, so a
    /// day on the ground has a few dozen of them, a few hundred on a long drive.
    static func dayGroups(_ photos: [Photo]) -> [DayGroup] {
        // The photos day by day, each day in time order (and time order is mostly day order).
        let keys = photos.map { dayKey($0.day) }
        let byDay = photos.indices.sorted { keys[$0] != keys[$1] ? keys[$0] < keys[$1] : $0 < $1 }
        var groups: [DayGroup] = []
        var first = 0
        while first < byDay.count {
            var end = first + 1
            while end < byDay.count && keys[byDay[end]] == keys[byDay[first]] { end += 1 }
            var members: [[Int]] = [], sums: [UnitVector] = [], centres: [UnitVector] = []
            for i in byDay[first..<end] {
                let point = UnitVector(photos[i].coordinate)
                var nearest = -1, nearestChord = Double.infinity
                for k in centres.indices {
                    let chord = point.chordSquared(to: centres[k])
                    if chord <= placeChordSquared && chord < nearestChord { (nearest, nearestChord) = (k, chord) }
                }
                if nearest >= 0 {
                    members[nearest].append(i)
                    sums[nearest] += point
                    centres[nearest] = sums[nearest].normalized ?? centres[nearest]
                } else {
                    members.append([i])
                    sums.append(point)
                    centres.append(point)
                }
            }
            for group in members where group.count >= TripGeometry.minimumPhotosPerPlace {
                let points = group.map { photos[$0].coordinate }
                groups.append(DayGroup(day: photos[group[0]].day, members: group, coordinate: GeoMath.dayPoint(points) ?? points[0]))
            }
            first = end
        }
        return groups.sorted { $0.members[0] < $1.members[0] }
    }

    /// The trip place of each day place, and how many there are: in time order, each day place
    /// joins the nearest place whose first day place lies within `TripGeometry.placeRadiusMeters`
    /// of its point, else it starts a new one (so places are numbered by first appearance). The
    /// hotel town of several days becomes one place. Measured from the place's first day place,
    /// which never moves, so places along a coast road do not chain into one. Day places of the
    /// same day merge too: two groups of one day whose running centres drifted within the
    /// radius are one place, not a zig-zag of the route inside one town.
    ///
    /// A day place is compared only with the places near it (`PlaceGrid`), not with every place
    /// before it: a trip has a few dozen places, but one the trip detection made of years of
    /// photos has thousands. The nearest by the same measure, ties to the lower index, so the
    /// places are those of comparing each.
    static func mergedPlaces(_ groups: [DayGroup]) -> (placeOfGroup: [Int], count: Int) {
        var grid = PlaceGrid()
        var placeOfGroup: [Int] = []
        placeOfGroup.reserveCapacity(groups.count)
        for group in groups {
            let point = UnitVector(group.coordinate)
            if let place = grid.nearest(to: point) {
                placeOfGroup.append(place)
            } else {
                placeOfGroup.append(grid.add(point))
            }
        }
        return (placeOfGroup, grid.count)
    }

    /// The first day places of a trip's places (their founders, `mergedPlaces`), on a grid of
    /// cubes over the space the unit sphere lies in, each as wide as the place radius in a
    /// straight line (`placeChordSquared`). Two points within the radius differ by less than
    /// that along each axis, so they lie in the same cube or in neighbouring ones: a point is
    /// compared with the founders of 27 cubes, whatever lies elsewhere. In space, not in latitude
    /// and longitude, so the antimeridian and the poles are no different.
    struct PlaceGrid {
        /// A cube's edge: a little longer than the radius as a straight line, so that rounding
        /// never puts two points within the radius more than one cube apart.
        static let edge = placeChordSquared.squareRoot() * (1 + 1e-6)
        /// Cubes on either side of the centre along an axis (the sphere reaches 1 from it), with
        /// room for the neighbours of the outermost: a cube's number is `(x, y, z)` in one `Int`.
        static let reach = Int((1 / edge).rounded(.up)) + 2

        /// The founders' points, by place.
        private(set) var founders: [UnitVector] = []
        /// The places whose founder lies in a cube, lowest first, by the cube's number.
        private var cubes: [Int: [Int]] = [:]

        var count: Int { founders.count }

        /// The nearest place whose founder lies within the radius of `point`, ties to the lower
        /// index; nil without one.
        func nearest(to point: UnitVector) -> Int? {
            let x = Self.cube(point.x), y = Self.cube(point.y), z = Self.cube(point.z)
            var nearest = -1, nearestChord = Double.infinity
            for dx in -1...1 {
                for dy in -1...1 {
                    for dz in -1...1 {
                        guard let places = cubes[Self.number(x + dx, y + dy, z + dz)] else { continue }
                        for p in places {
                            let chord = point.chordSquared(to: founders[p])
                            if chord <= placeChordSquared && (chord < nearestChord || (chord == nearestChord && p < nearest)) {
                                (nearest, nearestChord) = (p, chord)
                            }
                        }
                    }
                }
            }
            return nearest >= 0 ? nearest : nil
        }

        /// A new place founded at `point`; its index.
        mutating func add(_ point: UnitVector) -> Int {
            founders.append(point)
            cubes[Self.number(Self.cube(point.x), Self.cube(point.y), Self.cube(point.z)), default: []].append(founders.count - 1)
            return founders.count - 1
        }

        /// The cube along one axis that `value` (-1 to 1) lies in. A point that is none on the
        /// sphere (no usable location gives one) lies in a cube of the grid too: it is within the
        /// radius of nothing and founds a place, as comparing each would have it.
        static func cube(_ value: Double) -> Int {
            guard value.isFinite else { return 0 }
            return Int((min(1, max(-1, value)) / edge).rounded(.down))
        }

        static func number(_ x: Int, _ y: Int, _ z: Int) -> Int {
            let span = 2 * reach + 1
            return ((x + reach) * span + (y + reach)) * span + (z + reach)
        }
    }

    /// The trip's photos as `tripPlace` reads them: those on the map in time order, what the
    /// later steps need of each (`Photo.source`), the facts (for `PreviewRank`) and the altitudes
    /// by photo.
    struct TripPhotos {
        var photos: [Photo]
        var sources: [Source]
        var facts: [AssetFacts]
        var altitudes: [AssetID: Double]
    }

    /// One distinct place of the trip from its photos (indices into `tripPhotos.photos`, time
    /// order) and its day places (time order).
    static func tripPlace(members: [Int], dayPlaces: [DayGroup], in tripPhotos: TripPhotos) -> TripPlace {
        let photos = tripPhotos.photos, sources = tripPhotos.sources, facts = tripPhotos.facts, altitudes = tripPhotos.altitudes
        var pointsOfInterest = NameCounter(), towns = NameCounter(), districts = NameCounter()
        var regions = NameCounter(), countries = NameCounter(), countryKeys = NameCounter()
        var covers = CoverPicker(limit: TripGeometry.coverCandidateLimit)
        for m in members {
            let source = sources[photos[m].source]
            pointsOfInterest.add(source.names.pointOfInterest)
            towns.add(source.names.town)
            districts.add(source.names.district)
            regions.add(source.names.region)
            countries.add(source.names.country)
            countryKeys.add(source.names.countryKey)
            if let cover = source.cover { covers.add(cover) }
        }
        // Pin and stack photos: the best of its ordinary analysed photos. `PreviewRank` reads much
        // of a fact, so it is asked of the best few pictures only; when one of them is no ordinary
        // photo, of all of them.
        if !covers.kept.allSatisfy({ PreviewRank(facts[$0.fact]) == .photo }) {
            covers = CoverPicker(limit: TripGeometry.coverCandidateLimit)
            for m in members {
                if let cover = sources[photos[m].source].cover, PreviewRank(facts[cover.fact]) == .photo { covers.add(cover) }
            }
        }
        // The point of interest when one names at least half of its photos ("Skógafoss"), else
        // the most common town, then district, region, country.
        var name: String?
        if let poi = pointsOfInterest.top, poi.count * 2 >= members.count {
            name = poi.name
        } else {
            name = [towns, districts, regions, countries].lazy.compactMap { $0.top?.name }.first
        }

        // Where most of its photos were over the whole trip, a real photo location:
        // `GeoMath.dayPoint` over all its photos in time order, whose sample spreads over its days
        // by their photos (for a place of one day place, that day place's point: the same photos).
        let coordinate = dayPlaces.count == 1 ? dayPlaces[0].coordinate
            : GeoMath.dayPoint(members.map { photos[$0].coordinate }) ?? photos[members[0]].coordinate
        var days: [LocalDay] = []
        for day in dayPlaces.map({ $0.day }).sorted() where days.last != day { days.append(day) }

        return TripPlace(coordinate: coordinate, name: name, countryKey: countryKeys.top?.name, photoCount: members.count, days: days,
                         coverCandidates: covers.ids,
                         altitude: altitudes.isEmpty ? nil : altitude(of: members.map { sources[photos[$0].source].id }, altitudes: altitudes))
    }

    /// The place's height (`TripPlace.altitude`): the mean of its highest photos that agree, those
    /// within `TripGeometry.altitudeSpreadMeters` below the highest one that has at least
    /// `TripGeometry.minimumPhotosPerPlace - 1` others that close ("nur, wenn die Höhen der Fotos
    /// zusammenpassen"); else none, and no "Höchstes Foto" from it. A summit is one place with
    /// the way up to it (3 km), so the photos on the way up must not take its height away, and a
    /// single photo with a wrong altitude makes none. Altitudes above
    /// `AirborneFilter.maximumAltitude` are from planes (concept §5) and count as none. Added up
    /// from the lowest, so the mean does not depend on the input order.
    static func altitude(of ids: [AssetID], altitudes: [AssetID: Double]) -> Double? {
        guard !altitudes.isEmpty else { return nil }
        let values = ids.compactMap { altitudes[$0] }.filter { $0.isFinite && $0 <= AirborneFilter.maximumAltitude }.sorted()
        let minimum = TripGeometry.minimumPhotosPerPlace
        guard values.count >= minimum else { return nil }
        // From the highest down: the values from `low` to `high` lie within the spread, and as
        // `high` comes down, `low` can only come down too.
        var low = values.count - 1
        for high in stride(from: values.count - 1, through: minimum - 1, by: -1) {
            low = min(low, high)
            while low > 0 && values[high] - values[low - 1] <= TripGeometry.altitudeSpreadMeters { low -= 1 }
            if high - low + 1 >= minimum { return values[low...high].reduce(0, +) / Double(high - low + 1) }
        }
        return nil
    }
}
