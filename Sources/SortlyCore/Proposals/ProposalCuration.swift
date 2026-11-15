import Foundation

/// The last step of suggesting: one album for one set of photos.
///
/// On the first iPhone (15.11., 5,683 photos) about 250 suggestions came out, many of them the
/// same photos under several names: the trip "Marokko", the country "Marokko" and its towns;
/// "Tickets" among the screenshots and among the documents; "Deutschland" with most of the
/// library. A suggestion list is read top to bottom, so every duplicate costs attention and
/// hides a good suggestion further down. The rules, in order:
/// 1. Where the user lives is not an album (see `LibraryProfile`).
/// 2. A country, region, town or theme seen on one trip only is that trip's album. It comes
///    back by itself after a second trip there. Likewise a screenshot album inside a document
///    album.
/// 3. Of two suggestions with (nearly) the same photos, the more telling one stays: a named
///    place, then a trip, then a place album (the more specific level first: the user chose
///    towns), then the album of a repeatedly visited place, then documents, screenshots,
///    themes, and last a place still waiting for a name.
/// Years, months, media types, messengers and people are left as they are: they are opt-in,
/// and the user asked for exactly that view.
extension ProposalEngine {
    /// A share of photos this high inside one trip makes a place or theme part of that trip.
    static let nestedShare = 0.9
    /// Two suggestions are the same album when each holds at least this share of the other.
    static let sameAlbumShare = 0.9

    func curated(_ proposals: [AlbumProposal], profile: LibraryProfile) -> [AlbumProposal] {
        let tripFolder = labels.folder(for: .trips)
        func isPlaceAlbum(_ p: AlbumProposal) -> Bool {
            if case .placeCollection = p.kind { return p.folderPath.first != tripFolder }
            return false
        }
        func isTheme(_ p: AlbumProposal) -> Bool {
            if case .imageCategory = p.kind { return true }
            return false
        }

        // 1. Everyday places.
        var list = proposals.filter { p in !(isPlaceAlbum(p) && p.placeKeys.contains(where: profile.isEveryday)) }

        // 2. Places and themes inside a single trip.
        var tripOf: [AssetID: Int] = [:]
        let trips = list.filter { $0.kind == .trip }
        for (index, trip) in trips.enumerated() { for id in trip.assetIDs { tripOf[id] = index } }
        if !trips.isEmpty {
            list.removeAll { p in
                guard isPlaceAlbum(p) || isTheme(p), !p.assetIDs.isEmpty else { return false }
                var perTrip: [Int: Int] = [:]
                for id in p.assetIDs { if let t = tripOf[id] { perTrip[t, default: 0] += 1 } }
                guard let most = perTrip.values.max() else { return false }
                return Double(most) >= Double(p.assetIDs.count) * Self.nestedShare
            }
        }

        // A screenshot album inside a document album: the documents already hold those
        // screenshots ("Flugbuchungen" inside "Tickets").
        var documentOf: [AssetID: [Int]] = [:]
        let documents = list.filter { if case .documentCategory = $0.kind { return true } else { return false } }
        for (index, document) in documents.enumerated() { for id in document.assetIDs { documentOf[id, default: []].append(index) } }
        if !documents.isEmpty {
            list.removeAll { p in
                guard case .screenshotCategory = p.kind, !p.assetIDs.isEmpty else { return false }
                var perDocument: [Int: Int] = [:]
                for id in p.assetIDs { for d in documentOf[id] ?? [] { perDocument[d, default: 0] += 1 } }
                guard let most = perDocument.values.max() else { return false }
                return Double(most) >= Double(p.assetIDs.count) * Self.nestedShare
            }
        }

        // 3. The same photos under two names.
        func preference(_ p: AlbumProposal) -> Int? {
            switch p.kind {
            case .frequentPlace: return p.requiresUserName ? 90 : 0
            case .trip: return 10
            case .placeCollection(let level):
                // Deeper levels first: a town before its country.
                return isPlaceAlbum(p) ? 20 + (PlaceLevel.pointOfInterest.rawValue - level.rawValue) : 40
            case .documentCategory: return 50
            case .screenshotCategory: return 60
            case .imageCategory: return 70
            default: return nil
            }
        }
        let ranked = list.enumerated().compactMap { offset, p in preference(p).map { (offset, $0) } }
            .sorted { a, b in
                let (pa, pb) = (list[a.0], list[b.0])
                if a.1 != b.1 { return a.1 < b.1 }
                if pa.assetIDs.count != pb.assetIDs.count { return pa.assetIDs.count > pb.assetIDs.count }
                return pa.id.rawValue < pb.id.rawValue
            }
        var keptOf: [AssetID: [Int]] = [:]
        var dropped = Set<Int>()
        for (offset, _) in ranked {
            let p = list[offset]
            var shared: [Int: Int] = [:]
            for id in p.assetIDs { for k in keptOf[id] ?? [] { shared[k, default: 0] += 1 } }
            let duplicate = shared.contains { kept, count in
                let larger = max(p.assetIDs.count, list[kept].assetIDs.count)
                return Double(count) >= Double(larger) * Self.sameAlbumShare
            }
            if duplicate {
                dropped.insert(offset)
            } else {
                for id in p.assetIDs { keptOf[id, default: []].append(offset) }
            }
        }
        return list.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
    }
}
