import Foundation

/// Offline country and first-level region lookup (speed-up 1, decided 2026-11-13).
///
/// Data: Natural Earth 1:10m Admin-0/Admin-1 (public domain), simplified to ≈ 330 m and
/// packed by `scripts/worldmap/build_world_map.py` (~5 MB). Borders are therefore coarse:
/// a point closer than `borderMarginMeters` to another country is reported as *ambiguous*
/// and must be confirmed by the online geocoder. Albumist never guesses at a border.
public struct OfflineWorldMap: Sendable {
    public enum Level: UInt8, Sendable { case country = 0, region = 1 }

    public struct Region: Sendable, Hashable {
        public let index: Int
        public let level: Level
        public let parent: Int?
        public let isoCode: String
        public let nameDE: String
        public let nameEN: String
        let minLat: Int32, minLon: Int32, maxLat: Int32, maxLon: Int32
        let firstRing: Int
        let ringCount: Int

        public func name(_ language: TitleLanguage) -> String { language == .german ? nameDE : nameEN }
    }

    /// Result of one lookup.
    public struct Match: Sendable, Hashable {
        public var country: Region?
        public var region: Region?
        /// No other country lies within the border margin.
        public var countryIsCertain: Bool
        /// No other region of the same country lies within the border margin.
        public var regionIsCertain: Bool
        /// Countries considered (inside or within the margin), nearest first.
        public var countryCandidates: [Region]
        /// The point lies in a disputed area (decision Fuchs 18.11.2026, review P1-11). Then
        /// `country` and `region` are nil (the map's view is one side's view) and
        /// `countryIsCertain` is true: the answer "disputed, not sure which country" is final,
        /// and Apple's lookup, which answers by the country of the device, does not change it.
        public var disputedArea: DisputedArea?

        public func components(language: TitleLanguage) -> PlaceComponents? {
            if let disputedArea { return PlaceComponents().inDisputedArea(disputedArea, language: language) }
            guard let country else { return nil }
            return PlaceComponents(
                isoCountryCode: country.isoCode.isEmpty ? nil : String(country.isoCode.prefix(2)),
                country: country.name(language),
                administrativeArea: regionIsCertain ? region?.name(language) : nil
            )
        }

        /// No country and no region: neither side's view (see `disputedArea`).
        mutating func markDisputed(_ area: DisputedArea) {
            disputedArea = area
            country = nil
            region = nil
            countryIsCertain = true
            regionIsCertain = true
        }
    }

    public enum FormatError: Error, Equatable { case badMagic, unsupportedVersion(Int), truncated }

    public let regions: [Region]
    public let borderMarginMeters: Double
    private let scale: Double
    private let ringOffsets: [Int]
    private let ringCounts: [Int]
    /// Per-ring bounding boxes (minLat, minLon, maxLat, maxLon in scaled units). A ring whose
    /// box does not contain the point cannot change even-odd containment, so only rings
    /// near the point are decoded during a lookup.
    private let ringBoxes: [(Int64, Int64, Int64, Int64)]
    private let pointStream: [UInt8]
    private let regionsByCountry: [Int: [Int]]

    public init(data: Data, borderMarginMeters: Double = 1_500) throws {
        var reader = ByteReader(bytes: [UInt8](data))
        guard try reader.bytes(4) == Array("SWM1".utf8) else { throw FormatError.badMagic }
        let version = Int(try reader.u16())
        guard version == 1 else { throw FormatError.unsupportedVersion(version) }
        _ = try reader.u16()
        scale = Double(try reader.i32())

        let stringCount = Int(try reader.u32())
        var strings: [String] = []
        strings.reserveCapacity(stringCount)
        for _ in 0..<stringCount {
            let length = Int(try reader.u16())
            strings.append(String(decoding: try reader.bytes(length), as: UTF8.self))
        }
        func string(_ i: UInt32) throws -> String {
            guard Int(i) < strings.count else { throw FormatError.truncated }
            return strings[Int(i)]
        }

        let regionCount = Int(try reader.u32())
        var regions: [Region] = []
        regions.reserveCapacity(regionCount)
        var byCountry: [Int: [Int]] = [:]
        for index in 0..<regionCount {
            let level = Level(rawValue: try reader.u8()) ?? .region
            _ = try reader.u8(); _ = try reader.u16()
            let parent = Int(try reader.i32())
            let iso = try string(try reader.u32())
            let de = try string(try reader.u32())
            let en = try string(try reader.u32())
            let minLat = try reader.i32(), minLon = try reader.i32(), maxLat = try reader.i32(), maxLon = try reader.i32()
            let firstRing = Int(try reader.u32()), ringCount = Int(try reader.u32())
            regions.append(Region(
                index: index, level: level, parent: parent >= 0 ? parent : nil, isoCode: iso, nameDE: de, nameEN: en,
                minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon, firstRing: firstRing, ringCount: ringCount
            ))
            if level == .region, parent >= 0 { byCountry[parent, default: []].append(index) }
        }

        let ringTotal = Int(try reader.u32())
        var offsets: [Int] = [], counts: [Int] = []
        offsets.reserveCapacity(ringTotal); counts.reserveCapacity(ringTotal)
        for _ in 0..<ringTotal {
            offsets.append(Int(try reader.u32()))
            counts.append(Int(try reader.u32()))
        }
        let streamLength = Int(try reader.u32())
        pointStream = try reader.bytes(streamLength)
        for r in regions where r.firstRing + r.ringCount > ringTotal { throw FormatError.truncated }

        var boxes: [(Int64, Int64, Int64, Int64)] = []
        boxes.reserveCapacity(ringTotal)
        for ring in 0..<ringTotal {
            var offset = offsets[ring]
            guard offset <= pointStream.count else { throw FormatError.truncated }
            var lat: Int64 = 0, lon: Int64 = 0
            var box = (Int64.max, Int64.max, Int64.min, Int64.min)
            for _ in 0..<counts[ring] {
                lat += Self.unzigzag(Self.varint(pointStream, &offset))
                lon += Self.unzigzag(Self.varint(pointStream, &offset))
                box = (min(box.0, lat), min(box.1, lon), max(box.2, lat), max(box.3, lon))
            }
            boxes.append(box)
        }
        ringBoxes = boxes

        self.regions = regions
        self.ringOffsets = offsets
        self.ringCounts = counts
        self.regionsByCountry = byCountry
        self.borderMarginMeters = borderMarginMeters
    }

    public var countryCount: Int { regions.lazy.filter { $0.level == .country }.count }

    /// Outline rings of a region for drawing (e.g. the travel atlas). Points closer than
    /// `minimumStepDegrees` to the previously kept point are dropped; rings that collapse
    /// to fewer than three points are skipped.
    public func outline(of region: Region, minimumStepDegrees: Double = 0) -> [[GeoCoordinate]] {
        var rings: [[GeoCoordinate]] = []
        let step2 = minimumStepDegrees * minimumStepDegrees
        for ring in region.firstRing..<(region.firstRing + region.ringCount) {
            var offset = ringOffsets[ring]
            var lat: Int64 = 0, lon: Int64 = 0
            var points: [GeoCoordinate] = []
            for _ in 0..<ringCounts[ring] {
                lat += Self.unzigzag(Self.varint(pointStream, &offset))
                lon += Self.unzigzag(Self.varint(pointStream, &offset))
                let point = GeoCoordinate(latitude: Double(lat) / scale, longitude: Double(lon) / scale)
                if let last = points.last {
                    let dLat = point.latitude - last.latitude, dLon = point.longitude - last.longitude
                    if dLat * dLat + dLon * dLon < step2 { continue }
                }
                points.append(point)
            }
            if points.count >= 3 { rings.append(points) }
        }
        return rings
    }

    // MARK: Lookup

    public func lookup(_ coordinate: GeoCoordinate) -> Match {
        let countries = evaluate(coordinate, among: regions.lazy.filter { $0.level == .country }.map(\.index))
        var match = Match(country: nil, region: nil, countryIsCertain: false, regionIsCertain: false, countryCandidates: countries.map { regions[$0.index] })
        guard let best = countries.first, best.inside || best.distance <= borderMarginMeters else {
            // At sea, or on an island the map does not draw, in a disputed area's waters.
            if let area = DisputedAreas.area(outlineContaining: coordinate, mapCountry: nil) { match.markDisputed(area) }
            return match
        }
        match.country = regions[best.index]
        // Certain if no other country is inside or within the margin.
        match.countryIsCertain = countries.dropFirst().allSatisfy { !$0.inside && $0.distance > borderMarginMeters }
        if let r = region(coordinate, inCountry: best.index) {
            match.region = r.region
            match.regionIsCertain = r.isCertain
        }
        if let area = DisputedAreas.area(mapCountry: match.country?.nameEN, mapRegion: match.region?.isoCode)
            ?? DisputedAreas.area(outlineContaining: coordinate, mapCountry: match.country?.nameEN) {
            match.markDisputed(area)
        }
        return match
    }

    /// Region lookup restricted to one country, e.g. after the online geocoder decided the
    /// country of a point at a border. Keeps region names identical across both sources.
    public func region(_ coordinate: GeoCoordinate, inCountryCode code: String) -> (region: Region, isCertain: Bool)? {
        guard let country = country(code: code) else { return nil }
        return region(coordinate, inCountry: country.index)
    }

    /// The map's country of a code. Where a disputed area shares the code (Northern Cyprus has
    /// "CY" in the map), the other one: Apple's "CY" south of the Green Line is the Republic of
    /// Cyprus, and a point in the disputed area never gets here (`lookup` marks it first).
    public func country(code: String) -> Region? {
        let upper = code.uppercased()
        let matches = regions.filter { $0.level == .country && $0.isoCode.uppercased() == upper }
        return matches.first { DisputedAreas.area(mapCountry: $0.nameEN, mapRegion: nil) == nil } ?? matches.first
    }

    /// Names stored places in one language (review P1-12: after the language of album names was
    /// switched, stored places kept the country and region names of the old one). Built once
    /// for many places.
    public struct Renamer: Sendable {
        public let language: TitleLanguage
        /// Countries by two-letter code (Cyprus and Northern Cyprus share one).
        let countries: [String: [Region]]
        /// Regions by "<country index>|<name in either language, normalized>".
        let regions: [String: Region]

        /// `place` with its country and first-level region named in `language`, as far as the
        /// map knows them: the country by its code (and its name, where two share a code), the
        /// region by its name in either language. Towns and everything else stay as they are
        /// (they come from Apple's lookup, not from the map).
        public func renamed(_ place: PlaceComponents) -> PlaceComponents {
            if let area = place.disputedArea.flatMap(DisputedAreas.area(id:)) {
                var result = place
                result.country = area.name(language)
                return result
            }
            guard let country = country(of: place) else { return place }
            var result = place
            result.country = country.name(language)
            if let region = region(of: place, in: country) {
                result.administrativeArea = region.name(language)
            }
            return result
        }

        /// The map's country of a stored place: by its code, and by its name where two share a code.
        func country(of place: PlaceComponents) -> Region? {
            guard let code = place.isoCountryCode?.uppercased(), let candidates = countries[code], !candidates.isEmpty else { return nil }
            let stored = place.country.map(PlaceKey.normalize)
            return candidates.first { stored != nil && (PlaceKey.normalize($0.nameDE) == stored || PlaceKey.normalize($0.nameEN) == stored) }
                ?? candidates.first { $0.isoCode.uppercased() == code }
        }

        /// The map's first-level region of a stored place, by its name in either language.
        func region(of place: PlaceComponents, in country: Region) -> Region? {
            place.administrativeArea.flatMap { regions["\(country.index)|\(PlaceKey.normalize($0))"] }
        }

        /// A name for the map's region of `place` that no language changes ("DE|DE-BY|bavaria"),
        /// or nil when the map does not know the region.
        public func regionIdentity(of place: PlaceComponents) -> String? {
            guard let country = country(of: place), let region = region(of: place, in: country) else { return nil }
            return "\(country.isoCode.prefix(2).uppercased())|\(region.isoCode)|\(PlaceKey.normalize(region.nameEN))"
        }
    }

    /// The region part of the place keys of one library (second review of P1-12): the region's
    /// name was part of every town's and region's key, so naming the region in the other
    /// language ("bayern" → "bavaria") gave their suggestions new ids and lost the user's
    /// decisions on them. Each region the map knows keeps one key for good, whatever language
    /// its name is in. A region seen for the first time keeps the key its stored places
    /// already have (the one most of them have), so no id changes when this is introduced.
    public struct RegionKeys: Codable, Sendable, Equatable {
        /// Keys by `Renamer.regionIdentity`.
        public var keys: [String: String]

        public init(keys: [String: String] = [:]) { self.keys = keys }

        /// `places` with the key of their region fixed; returns only the places that changed.
        /// Places of a region the map does not know keep their name as key (the map cannot
        /// rename them either).
        public mutating func fix(_ places: [AssetID: ResolvedPlace], with renamer: Renamer) -> [AssetID: ResolvedPlace] {
            var identities: [AssetID: String] = [:]
            var votes: [String: [String: Int]] = [:]
            for (id, place) in places {
                guard let area = place.components.administrativeArea, let identity = renamer.regionIdentity(of: place.components) else { continue }
                identities[id] = identity
                guard keys[identity] == nil else { continue }
                // A key fixed before outweighs any number of names.
                let vote = place.components.administrativeAreaKey ?? PlaceKey.normalize(area)
                votes[identity, default: [:]][vote, default: 0] += place.components.administrativeAreaKey == nil ? 1 : places.count + 1
            }
            for (identity, counts) in votes {
                keys[identity] = counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
            }
            var changed: [AssetID: ResolvedPlace] = [:]
            for (id, identity) in identities {
                guard var place = places[id], let key = keys[identity], place.components.administrativeAreaKey != key else { continue }
                place.components.administrativeAreaKey = key
                changed[id] = place
            }
            return changed
        }
    }

    public func renamer(to language: TitleLanguage) -> Renamer {
        var countries: [String: [Region]] = [:]
        var named: [String: Region] = [:]
        for r in regions {
            switch r.level {
            case .country:
                guard r.isoCode.count >= 2 else { continue }
                countries[String(r.isoCode.prefix(2)).uppercased(), default: []].append(r)
            case .region:
                guard let parent = r.parent else { continue }
                for name in [r.nameDE, r.nameEN] where named["\(parent)|\(PlaceKey.normalize(name))"] == nil {
                    named["\(parent)|\(PlaceKey.normalize(name))"] = r
                }
            }
        }
        return Renamer(language: language, countries: countries, regions: named)
    }

    /// One place named in `language` (see `Renamer`).
    public func renamed(_ place: PlaceComponents, to language: TitleLanguage) -> PlaceComponents {
        renamer(to: language).renamed(place)
    }

    private func region(_ coordinate: GeoCoordinate, inCountry country: Int) -> (region: Region, isCertain: Bool)? {
        guard let children = regionsByCountry[country] else { return nil }
        let candidates = evaluate(coordinate, among: children)
        guard let best = candidates.first, best.inside || best.distance <= borderMarginMeters else { return nil }
        let certain = candidates.dropFirst().allSatisfy { !$0.inside && $0.distance > borderMarginMeters }
        return (regions[best.index], certain)
    }

    private struct Candidate { var index: Int; var inside: Bool; var distance: Double }

    /// Containment and boundary distance for every region whose bounding box (plus margin)
    /// contains the point. Sorted: containing regions first, then by distance.
    private func evaluate<S: Sequence>(_ c: GeoCoordinate, among indices: S) -> [Candidate] where S.Element == Int {
        let marginLat = borderMarginMeters / GeoMath.metersPerDegreeLatitude
        let marginLon = marginLat / max(cos(c.latitude * .pi / 180), 0.01)
        let lat = c.latitude * scale, lon = c.longitude * scale
        let mLat = marginLat * scale, mLon = marginLon * scale
        var result: [Candidate] = []
        for i in indices {
            let r = regions[i]
            guard lat >= Double(r.minLat) - mLat, lat <= Double(r.maxLat) + mLat,
                  lon >= Double(r.minLon) - mLon, lon <= Double(r.maxLon) + mLon else { continue }
            let (inside, distance) = containment(c, region: r, marginLat: mLat, marginLon: mLon)
            guard inside || distance.isFinite else { continue }
            result.append(Candidate(index: i, inside: inside, distance: distance))
        }
        return result.sorted { ($0.inside ? 0 : 1, $0.distance, $0.index) < ($1.inside ? 0 : 1, $1.distance, $1.index) }
    }

    /// Even-odd containment plus the distance to the nearest boundary segment in metres
    /// (local equirectangular projection; exact enough for distances of a few kilometres).
    private func containment(_ c: GeoCoordinate, region r: Region, marginLat: Double, marginLon: Double) -> (Bool, Double) {
        let metersPerLon = GeoMath.metersPerDegreeLatitude * cos(c.latitude * .pi / 180)
        let qLat = c.latitude * scale, qLon = c.longitude * scale
        var inside = false
        var best = Double.infinity
        for ring in r.firstRing..<(r.firstRing + r.ringCount) {
            let box = ringBoxes[ring]
            guard qLat >= Double(box.0) - marginLat, qLat <= Double(box.2) + marginLat,
                  qLon >= Double(box.1) - marginLon, qLon <= Double(box.3) + marginLon else { continue }
            var offset = ringOffsets[ring]
            let count = ringCounts[ring]
            var lat: Int64 = 0, lon: Int64 = 0
            var firstX = 0.0, firstY = 0.0, prevX = 0.0, prevY = 0.0
            for p in 0..<count {
                lat += Self.unzigzag(Self.varint(pointStream, &offset))
                lon += Self.unzigzag(Self.varint(pointStream, &offset))
                // Projected coordinates relative to the query point, in metres.
                let x = (Double(lon) / scale - c.longitude) * metersPerLon
                let y = (Double(lat) / scale - c.latitude) * GeoMath.metersPerDegreeLatitude
                if p == 0 {
                    firstX = x; firstY = y
                } else {
                    Self.edge(prevX, prevY, x, y, inside: &inside, best: &best)
                }
                prevX = x; prevY = y
            }
            if count > 1 { Self.edge(prevX, prevY, firstX, firstY, inside: &inside, best: &best) }
        }
        return (inside, best)
    }

    @inline(__always)
    private static func edge(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, inside: inout Bool, best: inout Double) {
        // Ray casting towards +x from the origin (the query point).
        if (ay > 0) != (by > 0) {
            let xCross = ax + (0 - ay) * (bx - ax) / (by - ay)
            if xCross > 0 { inside.toggle() }
        }
        let dx = bx - ax, dy = by - ay
        let length2 = dx * dx + dy * dy
        var t = length2 > 0 ? -(ax * dx + ay * dy) / length2 : 0
        t = min(max(t, 0), 1)
        let px = ax + t * dx, py = ay + t * dy
        let d = (px * px + py * py).squareRoot()
        if d < best { best = d }
    }

    @inline(__always)
    private static func varint(_ bytes: [UInt8], _ offset: inout Int) -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < bytes.count {
            let byte = bytes[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
        }
        return result
    }

    @inline(__always)
    private static func unzigzag(_ n: UInt64) -> Int64 { Int64(bitPattern: (n >> 1) ^ (0 &- (n & 1))) }
}

private struct ByteReader {
    let bytes: [UInt8]
    var offset = 0

    mutating func bytes(_ n: Int) throws -> [UInt8] {
        guard n >= 0, offset + n <= bytes.count else { throw OfflineWorldMap.FormatError.truncated }
        defer { offset += n }
        return Array(bytes[offset..<(offset + n)])
    }

    mutating func u8() throws -> UInt8 { try bytes(1)[0] }

    mutating func u16() throws -> UInt16 {
        let b = try bytes(2)
        return UInt16(b[0]) | UInt16(b[1]) << 8
    }

    mutating func u32() throws -> UInt32 {
        let b = try bytes(4)
        return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }

    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
}
