import Foundation

/// Everything Albumist knows about one asset after analysis. Input for rules, search,
/// status and proposals. Built from persisted analysis results.
public struct AssetFacts: Hashable, Sendable, Identifiable {
    public var asset: AssetSnapshot
    public var place: PlaceComponents?
    public var placeSource: PlaceSource?
    public var frequentPlaceID: SortlyID?
    public var tripID: SortlyID?
    /// Image category id → reliability (only categories at or above "plausible").
    public var categories: [String: Reliability]
    /// Screenshot content categories.
    public var textCategories: Set<String>
    public var document: DocumentInfo?
    public var messenger: MessengerAssessment?
    /// Confirmed person/pet group ids.
    public var groupIDs: Set<SortlyID>
    public var albumIDs: Set<CollectionID>
    /// Recognized text, kept only on device for search.
    public var recognizedText: String? {
        didSet { textLooksSensitive = recognizedText.map(TextMinimizer.looksSensitive) ?? false }
    }
    /// The stored text shows a bank card, a statement or another sensitive paper
    /// (`TextMinimizer.looksSensitive`). Worked out with the text, where the facts are assembled
    /// (off the main thread), so ranking a whole library for previews reads no text (`PreviewRank`).
    public private(set) var textLooksSensitive: Bool
    public var keywords: Set<String>
    /// Taken where the user lives (`TripAnalysis.atHome`): no place album is made for it.
    public var atHome: Bool
    /// The image analysis took it for a document, receipt, card or other utility picture
    /// (`ContentAnalysis.isDocumentLike`): a poor preview or cover (`PreviewRank`).
    public var looksLikeDocument: Bool
    /// The image analysis has looked at it (`FactsAssembler`: a content result that is not a
    /// failed read). Until then nothing says whether it is a card: it ranks below every analysed
    /// ordinary photo for previews and covers (`PreviewRank.unknown`) and is never the photo of
    /// the shared atlas image. `false` unless stated: only the analysis says it.
    public var contentKnown: Bool

    public init(
        asset: AssetSnapshot,
        place: PlaceComponents? = nil,
        placeSource: PlaceSource? = nil,
        frequentPlaceID: SortlyID? = nil,
        tripID: SortlyID? = nil,
        categories: [String: Reliability] = [:],
        textCategories: Set<String> = [],
        document: DocumentInfo? = nil,
        messenger: MessengerAssessment? = nil,
        groupIDs: Set<SortlyID> = [],
        albumIDs: Set<CollectionID> = [],
        recognizedText: String? = nil,
        keywords: Set<String> = [],
        atHome: Bool = false,
        looksLikeDocument: Bool = false,
        contentKnown: Bool = false
    ) {
        self.asset = asset
        self.place = place
        self.placeSource = placeSource
        self.frequentPlaceID = frequentPlaceID
        self.tripID = tripID
        self.categories = categories
        self.textCategories = textCategories
        self.document = document
        self.messenger = messenger
        self.groupIDs = groupIDs
        self.albumIDs = albumIDs
        self.recognizedText = recognizedText
        self.keywords = keywords
        self.atHome = atHome
        self.looksLikeDocument = looksLikeDocument
        self.contentKnown = contentKnown
        textLooksSensitive = recognizedText.map(TextMinimizer.looksSensitive) ?? false
    }

    public var id: AssetID { asset.id }

    /// Place usable for geographic organization: GPS-based only. Content guesses are
    /// shown separately and never used here (prompt §4.1).
    public var gpsPlace: PlaceComponents? {
        placeSource == .gpsReverseGeocoded || placeSource == .userAssigned ? place : nil
    }

    public func hasCategory(_ id: String, minimum: Reliability = .likely) -> Bool {
        if let r = categories[id], r >= minimum { return true }
        // Parent categories match their children: "vehicle" matches "vehicle.car".
        let prefix = id + "."
        return categories.contains { $0.key.hasPrefix(prefix) && $0.value >= minimum }
    }
}
