import Foundation
import SortlyCore

/// Result of the text stage for one asset (stored as analysis result kind "text").
public struct TextResult: Hashable, Sendable, Codable {
    public var text: TextAnalysis?
    public var document: DocumentInfo?
    public var screenshotCategories: [String]
    /// The original is only in iCloud and downloading was not allowed: read later.
    public var waitingForOriginal: Bool
    /// Reads that gave no final result yet (only the small preview could be read, or the
    /// image could not be read at all). Retried a few times, spaced out. `nil` = final.
    public var retries: Int?
    public var lastAttempt: Date?

    public init(text: TextAnalysis? = nil, document: DocumentInfo? = nil, screenshotCategories: [String] = [], waitingForOriginal: Bool = false,
                retries: Int? = nil, lastAttempt: Date? = nil) {
        self.text = text
        self.document = document
        self.screenshotCategories = screenshotCategories
        self.waitingForOriginal = waitingForOriginal
        self.retries = retries
        self.lastAttempt = lastAttempt
    }

    /// Up to this many reads without a final result; then the result stays as it is.
    public static let maxRetries = 3
    /// Time between two of those reads.
    public static let retrySpacing: TimeInterval = 3600

    /// Whether the text stage should read this photo again.
    public func shouldRetry(networkAllowed: Bool, now: Date) -> Bool {
        if waitingForOriginal { return networkAllowed }
        // Results from older versions: a preview read or an unreadable image count as one try.
        let tries = retries ?? ((text == nil || text?.source == .localPreview) ? 1 : 0)
        guard tries > 0, tries < Self.maxRetries else { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < Self.retrySpacing { return false }
        // A preview read gets better only from the original, which may need the network.
        return text?.source == .localPreview ? networkAllowed : true
    }
}

/// Scope of a trial run ("Albumist arbeitet mit", one year): the first organization covers
/// only one year or one album, so the user can check the result calmly before organizing
/// everything.
public enum OrganizationScope: Hashable, Sendable, Codable {
    case all
    case year(Int)
    case album(CollectionID)

    /// A year is the year on the photo's own clock (review P1-15, `LocalTime`): New Year's Eve in
    /// New York belongs to the old year also on an iPhone on German time. `calendar`'s zone counts
    /// only for facts made without zones.
    public func includes(_ facts: AssetFacts, calendar: Calendar) -> Bool {
        switch self {
        case .all: true
        case .year(let y): facts.wallClock(or: calendar.timeZone).map { LocalTime.wallCalendar(calendar).component(.year, from: $0) == y } ?? false
        case .album(let id): facts.albumIDs.contains(id)
        }
    }
}

/// Joins stored analysis results into the per-asset facts the proposal engine, status
/// resolver and search work on. With `homeTimeZone` each photo gets the time zone of its clock
/// (`AssetFacts.timeZone`, `PhotoClocks`, review P1-15): its place's, else its country's there,
/// else, on a trip, the trip's; else that one.
/// `placeZones`: the zones of the places (`LocalTime.placeZones`) where the caller has them.
/// `stop`: asked every 1,000 photos (see the loop).
public enum FactsAssembler {
    public static func assemble(
        assets: [AssetSnapshot],
        places: [AssetID: ResolvedPlace],
        contents: [AssetID: ContentAnalysis],
        texts: [AssetID: TextResult],
        trips: [Trip],
        frequentPlaces: [FrequentPlace],
        groups: [ObservationGroup],
        inventory: CollectionInventory,
        home: Set<AssetID> = [],
        withoutCountry: Set<AssetID> = [],
        homeTimeZone: TimeZone? = nil,
        placeZones: [AssetID: TimeZone]? = nil,
        stoppingWhen stop: () -> Bool = { false }
    ) -> [AssetFacts] {
        var tripOf: [AssetID: SortlyID] = [:]
        for trip in trips { for id in trip.geotaggedAssetIDs { tripOf[id] = trip.id } }
        var frequentOf: [AssetID: SortlyID] = [:]
        for place in frequentPlaces { for id in place.assetIDs { frequentOf[id] = place.id } }
        var groupsOf: [AssetID: Set<SortlyID>] = [:]
        for group in groups where group.isConfirmed { for id in group.assetIDs { groupsOf[id, default: []].insert(group.id) } }
        let membership = inventory.albumMembershipIndex()
        let titles = inventory.collections.mapValues(\.title)
        let messenger = MessengerClassifier()
        let clocks = homeTimeZone.map { PhotoClocks(places: placeZones ?? LocalTime.placeZones(of: assets, places: places), trips: trips, home: $0) }

        func facts(of asset: AssetSnapshot) -> AssetFacts {
            let place = places[asset.id]
            let content = contents[asset.id]
            let text = texts[asset.id]
            let albums = membership[asset.id] ?? []
            let recognized = text?.text?.text
            let assessment = messenger.assess(asset: asset, recognizedText: recognized, albumTitles: albums.compactMap { titles[$0] })
            let categories = content.map { ImageTaxonomy.categories(from: $0.labels.map { ($0.identifier, $0.confidence) }) } ?? [:]
            var facts = AssetFacts(
                asset: asset,
                place: place?.components,
                placeSource: place?.source,
                frequentPlaceID: frequentOf[asset.id],
                tripID: tripOf[asset.id],
                categories: categories,
                textCategories: Set(text?.screenshotCategories ?? []),
                document: text?.document,
                messenger: assessment.evidence > .unknownOrigin ? assessment : nil,
                groupIDs: groupsOf[asset.id] ?? [],
                albumIDs: Set(albums),
                recognizedText: recognized,
                keywords: Set(content?.labels.filter { $0.confidence >= 0.5 }.map(\.identifier) ?? []),
                atHome: home.contains(asset.id),
                looksLikeDocument: content?.isDocumentLike ?? false,
                // A failed read says nothing about the picture: it stays unknown.
                contentKnown: content.map { $0.failedAttempts == nil } ?? false,
                // Only while it has no place: one found since wins.
                countryOutOfReach: place == nil && withoutCountry.contains(asset.id)
            )
            facts.timeZone = clocks?.zone(of: asset.id)
            return facts
        }

        var all: [AssetFacts] = []
        all.reserveCapacity(assets.count)
        for (index, asset) in assets.enumerated() {
            // Given up, the facts so far are returned: only for work whose result is dropped
            // then (an analysis run paused meanwhile, review P4-07).
            if index % 1_000 == 0, stop() { return all }
            all.append(facts(of: asset))
        }
        return all
    }
}
