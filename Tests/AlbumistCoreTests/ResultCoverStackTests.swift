import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// The big moment after a run (draft E3, design wave 2): the covers of the new albums lie fanned
/// above "10 neue Alben". Which albums, which photos each one tries, in which order and how many
/// is decided here (`ResultCoverStack`); the app only loads what is sharp on the device and lays
/// it down. Undo, removal and failed steps keep the symbol they always had; so does a run whose
/// albums have no photo that may be shown (sensitive documents, personal suggestions).
@Suite("Result cover stack")
struct ResultCoverStackTests {
    static let new = ProposalDecision.createNew(title: nil, folderPath: nil)

    /// A trip with `count` photos "<id>-1" … "<id>-<count>".
    static func trip(_ id: String, photos count: Int = 3, cover: AssetID? = nil) -> AlbumProposal {
        AlbumProposal(id: AlbumistID(id), kind: .trip, title: "Reise \(id)", folderPath: ["Reisen"],
                      assetIDs: Set((1...count).map { AssetID("\(id)-\($0)") }), coverAssetID: cover)
    }

    static func confirmed(_ plan: ChangePlan) -> ChangePlan {
        var p = plan
        p.confirmedAt = Date()
        p.status = .confirmed
        return p
    }

    static func run(_ plan: ChangePlan, in library: InMemoryPhotoLibrary) async throws -> ChangePlan {
        try await ChangeExecutor(library: library, store: InMemoryPlanStore()).execute(confirmed(plan))
    }

    /// The plan for `items` and the same plan after its run.
    static func planAndRun(_ items: [ConfirmedProposal], in library: InMemoryPhotoLibrary) async throws -> (planned: ChangePlan, made: ChangePlan) {
        let plan = OrganizationPlanner().makePlan(from: items, inventory: try await library.currentInventory())
        let made = try await run(plan, in: library)
        #expect(made.status == .completed)
        return (plan, made)
    }

    static func library(_ proposals: [AlbumProposal], extra: Set<AssetID> = [], collections: [CollectionSnapshot] = []) -> InMemoryPhotoLibrary {
        InMemoryPhotoLibrary(assets: proposals.reduce(extra) { $0.union($1.assetIDs) }, collections: collections)
    }

    // MARK: Which albums

    /// New albums come first: a run that made albums and added photos to one of the user's shows
    /// the new ones only ("1 neues Album" above two covers would count two albums).
    @Test func theNewAlbumsComeFirst() async throws {
        let kyoto = Self.trip("kyoto"), rom = Self.trip("rom"), lissabon = Self.trip("lissabon")
        let mine = CollectionSnapshot(id: "mine", title: "Italien", assetIDs: ["own"])
        let library = Self.library([kyoto, rom, lissabon], extra: ["own"], collections: [mine])
        let (_, made) = try await Self.planAndRun([ConfirmedProposal(proposal: kyoto, decision: Self.new),
                                                  ConfirmedProposal(proposal: rom, decision: .extendExisting("mine")),
                                                  ConfirmedProposal(proposal: lissabon, decision: Self.new)], in: library)
        let stack = ResultCoverStack(plan: made)
        #expect(stack.albums == .created)
        #expect(stack.cards.count == 2)
        #expect(stack.cards.allSatisfy { $0.id.hasPrefix("planned:") }, "\(stack.cards.map(\.id))")
        // In the order of the plan: Kyoto, then Lisbon.
        #expect(stack.cards.map { $0.candidates.first?.rawValue.components(separatedBy: "-").first } == ["kyoto", "lissabon"])
    }

    /// Nothing made, photos added to albums of the user's: their covers ("12 Fotos in 3 deiner
    /// Alben ergänzt").
    @Test func theUsersAlbumsWhenNothingWasMade() async throws {
        let kyoto = Self.trip("kyoto"), rom = Self.trip("rom")
        let japan = CollectionSnapshot(id: "japan", title: "Japan", assetIDs: ["own1"])
        let italy = CollectionSnapshot(id: "italy", title: "Italien", assetIDs: ["own2"])
        let library = Self.library([kyoto, rom], extra: ["own1", "own2"], collections: [japan, italy])
        let (_, made) = try await Self.planAndRun([ConfirmedProposal(proposal: kyoto, decision: .extendExisting("japan")),
                                                  ConfirmedProposal(proposal: rom, decision: .extendExisting("italy"))], in: library)
        let stack = ResultCoverStack(plan: made)
        #expect(stack.albums == .extended)
        #expect(stack.cards.map(\.id) == ["japan", "italy"])
        // Only photos the run added: never the user's own photo of the album.
        #expect(stack.cards.allSatisfy { !$0.candidates.contains("own1") && !$0.candidates.contains("own2") })
    }

    /// One album is one card, with a few photos to try for its cover (the app shows the first one
    /// that is sharp on the device).
    @Test func oneAlbumIsOneCard() async throws {
        let kyoto = Self.trip("kyoto", photos: 16)
        let library = Self.library([kyoto])
        let (_, made) = try await Self.planAndRun([ConfirmedProposal(proposal: kyoto, decision: Self.new)], in: library)
        let stack = ResultCoverStack(plan: made)
        #expect(stack.cards.count == 1)
        let candidates = try #require(stack.cards.first?.candidates)
        #expect(candidates.count == ResultCoverStack.candidatesPerCard)
        #expect(Set(candidates).count == candidates.count)
        #expect(candidates.allSatisfy { kyoto.assetIDs.contains($0) })
    }

    /// Ten new albums: eight are tried (an album whose photos are only in iCloud makes room for
    /// the next), five lie on the stack, three at the largest text sizes.
    @Test func atMostFiveCoversLieOnTheStack() async throws {
        let trips = (0..<10).map { Self.trip("t\($0)", photos: 2) }
        let library = Self.library(trips)
        let (_, made) = try await Self.planAndRun(trips.map { ConfirmedProposal(proposal: $0, decision: Self.new) }, in: library)
        let stack = ResultCoverStack(plan: made)
        #expect(stack.cards.count == ResultCoverStack.tried)
        #expect(ResultCoverStack.limit == 5 && ResultCoverStack.limitAtLargestText == 3)
        var sharp: [String: AssetID] = [:]
        for card in stack.cards { sharp[card.id] = card.candidates.first }
        #expect(stack.shown(sharp: sharp, limit: ResultCoverStack.limit).count == 5)
        #expect(stack.shown(sharp: sharp, limit: ResultCoverStack.limitAtLargestText).count == 3)
        // Cards without a sharp photo are left out; the next ones take their place, in order.
        sharp[stack.cards[0].id] = nil
        sharp[stack.cards[2].id] = nil
        let shown = stack.shown(sharp: sharp, limit: 5)
        #expect(shown.map(\.card) == [stack.cards[1], stack.cards[3], stack.cards[4], stack.cards[5], stack.cards[6]].map(\.id))
    }

    /// Four covers are laid as three: the main cover keeps the middle of the fan (draft E3). Two
    /// stay two.
    @Test func fourCoversAreLaidAsThree() async throws {
        let trips = (0..<4).map { Self.trip("t\($0)", photos: 2) }
        let library = Self.library(trips)
        let (_, made) = try await Self.planAndRun(trips.map { ConfirmedProposal(proposal: $0, decision: Self.new) }, in: library)
        let stack = ResultCoverStack(plan: made)
        var sharp: [String: AssetID] = [:]
        for card in stack.cards { sharp[card.id] = card.candidates.first }
        #expect(stack.shown(sharp: sharp, limit: 5).map(\.card) == stack.cards.prefix(3).map(\.id))
        sharp[stack.cards[3].id] = nil
        sharp[stack.cards[2].id] = nil
        #expect(stack.shown(sharp: sharp, limit: 5).count == 2)
    }

    // MARK: No stack

    /// No stack, the symbol as before: an undo, a removal, a run with failed steps, a run that
    /// confirmed nothing.
    @Test func undoRemovalAndFailuresKeepTheSymbol() async throws {
        let kyoto = Self.trip("kyoto"), rom = Self.trip("rom")
        let library = Self.library([kyoto, rom])
        let (planned, made) = try await Self.planAndRun([ConfirmedProposal(proposal: kyoto, decision: Self.new)], in: library)
        #expect(!ResultCoverStack(plan: made).isEmpty)

        // Undo.
        let tracker = ManagedAlbumTracker()
        let inventory = try await library.currentInventory()
        let states = tracker.record(made, into: [], inventory: inventory)
        let undo = try await Self.run(UndoPlanner().undoPlan(for: made, albums: states, current: inventory, earlierUndos: []), in: library)
        #expect(ResultCoverStack(plan: undo).isEmpty)
        #expect(ResultCoverStack(plan: undo, expected: true).isEmpty)

        // Removal from "Alben von Albumist".
        let (_, romMade) = try await Self.planAndRun([ConfirmedProposal(proposal: rom, decision: Self.new)], in: library)
        let romState = try #require(tracker.record(romMade, into: [], inventory: try await library.currentInventory()).first)
        let removal = try await Self.run(tracker.removalPlan(for: romState, current: try await library.currentInventory()), in: library)
        #expect(ResultCoverStack(plan: removal).isEmpty)
        #expect(ResultCoverStack(plan: removal, expected: true).isEmpty)

        // A step failed: "Teilweise fertig" under its symbol.
        var failed = made
        let add = try #require(failed.steps.firstIndex { if case .addAssets = $0.operation { true } else { false } })
        failed.steps[add].state = .failed(reason: "Fotos hat nicht geantwortet.")
        #expect(PlanReceipt(plan: failed, inventory: CollectionInventory()).failedSteps == 1)
        #expect(ResultCoverStack(plan: failed).isEmpty)

        // Nothing confirmed.
        var nothing = planned
        for index in nothing.steps.indices { nothing.steps[index].state = .failed(reason: "") }
        #expect(ResultCoverStack(plan: nothing).isEmpty)
        #expect(ResultCoverStack(plan: nothing).albums == nil)
    }

    // MARK: Which photos

    /// Never a sensitive document, never a screenshot or another document (a big cover is a
    /// photo, design rule 9): an album of only those has no card.
    @Test func sensitiveAndDocumentsNeverLieOnTheStack() async throws {
        let cards = AlbumProposal(id: AlbumistID("cards"), kind: .documentCategory("bank"), title: "Karten", assetIDs: ["card1", "card2"])
        let kyoto = Self.trip("kyoto")
        let library = Self.library([cards, kyoto])
        let (_, made) = try await Self.planAndRun([ConfirmedProposal(proposal: cards, decision: Self.new),
                                                  ConfirmedProposal(proposal: kyoto, decision: Self.new)], in: library)
        let ranks: [AssetID: PreviewRank] = ["card1": .sensitive, "card2": .document, "kyoto-1": .sensitive]
        let stack = ResultCoverStack(plan: made, ranks: ranks)
        #expect(stack.cards.count == 1)
        let candidates = try #require(stack.cards.first?.candidates)
        #expect(Set(candidates) == ["kyoto-2", "kyoto-3"])
    }

    /// A personal suggestion's album ("Ansehen …", "Vorschau ausgeblendet") never lies on the
    /// stack, and its photos are no other album's cover either.
    @Test func personalSuggestionsStayOffTheStack() async throws {
        let family = AlbumProposal(id: AlbumistID("family"), kind: .personOrPet, title: "Familie",
                                   assetIDs: ["shared", "fam-1"], isSensitive: true)
        let kyoto = AlbumProposal(id: AlbumistID("kyoto"), kind: .trip, title: "Kyoto", assetIDs: ["shared", "kyoto-1"])
        let library = Self.library([family, kyoto])
        let (_, made) = try await Self.planAndRun([ConfirmedProposal(proposal: family, decision: Self.new),
                                                  ConfirmedProposal(proposal: kyoto, decision: Self.new)], in: library)
        let dates: [AssetID: Date] = ["shared": Date(timeIntervalSince1970: 2_000), "kyoto-1": Date(timeIntervalSince1970: 1_000)]
        let open = ResultCoverStack(plan: made, dates: dates)
        #expect(open.cards.count == 2)

        let stack = ResultCoverStack(plan: made, dates: dates, personalSources: [family.id])
        #expect(stack.cards.count == 1)
        #expect(stack.cards.first?.candidates == ["kyoto-1"], "a photo of the personal album was offered as a cover")

        // Only a personal album: no stack.
        let alone = Self.library([family])
        let (_, familyMade) = try await Self.planAndRun([ConfirmedProposal(proposal: family, decision: Self.new)], in: alone)
        #expect(ResultCoverStack(plan: familyMade, personalSources: [family.id]).isEmpty)
    }

    /// A suggestion the analysis does not know may have been personal: a step keeps the
    /// suggestion it came from, also in "Fehlendes erneut versuchen" and after the analysis made
    /// its suggestions anew, so an unknown one stays off the stack, at the plan's start as at its
    /// end (review E of design wave 2, finding 10). Known ones are personal only when they are.
    @Test func anUnknownSuggestionCountsAsPersonal() async throws {
        let family = AlbumProposal(id: AlbumistID("family"), kind: .personOrPet, title: "Familie",
                                   assetIDs: ["fam-1", "fam-2"], isSensitive: true)
        let kyoto = Self.trip("kyoto")
        let library = Self.library([family, kyoto])
        let (planned, _) = try await Self.planAndRun([ConfirmedProposal(proposal: family, decision: Self.new),
                                                     ConfirmedProposal(proposal: kyoto, decision: Self.new)], in: library)
        #expect(ResultCoverStack.personalSources(of: planned, known: [family.id, kyoto.id], personal: []).isEmpty)
        #expect(ResultCoverStack.personalSources(of: planned, known: [family.id, kyoto.id], personal: [family.id]) == [family.id])
        // Personal suggestions of other plans do not matter here.
        #expect(ResultCoverStack.personalSources(of: planned, known: [family.id, kyoto.id], personal: [AlbumistID("other")]).isEmpty)
        // The analysis made its suggestions anew: the family's old id is unknown now.
        #expect(ResultCoverStack.personalSources(of: planned, known: [kyoto.id], personal: []) == [family.id])
        #expect(ResultCoverStack.personalSources(of: planned, known: [], personal: []) == [family.id, kyoto.id])

        // "Fehlendes erneut versuchen": the family's photos did not arrive in its album the first
        // time. The retry adds them to the album that run made, under the family's old id.
        let alone = Self.library([family])
        let (_, made) = try await Self.planAndRun([ConfirmedProposal(proposal: family, decision: Self.new)], in: alone)
        var gapped = made
        let add = try #require(gapped.steps.firstIndex { if case .addAssets = $0.operation { true } else { false } })
        gapped.steps[add].state = .failed(reason: "Fotos hat nicht geantwortet.")
        gapped.status = .completedWithErrors
        let key = try #require(gapped.steps.lazy.compactMap { step -> String? in
            if case .createAlbum(let key, _, _) = step.operation { key } else { nil }
        }.first)
        let album = try #require(gapped.resolvedKeys[key])
        try await alone.removeAssets(["fam-1", "fam-2"], from: album)
        let retry = try #require(RetryPlanner().retryPlan(for: gapped, current: try await alone.currentInventory()))
        #expect(!retry.steps.isEmpty && retry.steps.allSatisfy { $0.sourceID == family.id })
        let retried = try await Self.run(retry, in: alone)
        #expect(retried.status == .completed)
        let open = ResultCoverStack(plan: retried)
        #expect(open.albums == .extended && open.cards.map(\.id) == [album.rawValue], "the family's photos would lie on the stack")
        let personal = ResultCoverStack.personalSources(of: retry, known: [AlbumistID("family-anew")], personal: [])
        #expect(personal == [family.id])
        #expect(ResultCoverStack(plan: retried, personalSources: personal).isEmpty)
    }

    /// The stack never shows more albums than the count above it says: an album found after an
    /// interruption ("adopted", counted as "Fotos einsortiert", not as new) lies on no card, in a
    /// run that made albums as in one that only added photos to the user's (review E, finding 16).
    @Test func neverMoreCoversThanTheCountSays() async throws {
        func key(of title: String, in plan: ChangePlan) throws -> String {
            try #require(plan.steps.lazy.compactMap { step -> String? in
                if case .createAlbum(let key, let name, _) = step.operation, name == title { key } else { nil }
            }.first)
        }
        func allSharp(_ stack: ResultCoverStack) -> [String: AssetID] {
            var sharp: [String: AssetID] = [:]
            for card in stack.cards { sharp[card.id] = card.candidates.first }
            return sharp
        }
        let kyoto = Self.trip("kyoto"), rom = Self.trip("rom"), lissabon = Self.trip("lissabon")
        let mine = CollectionSnapshot(id: "mine", title: "Italien", assetIDs: ["own"])
        let library = Self.library([kyoto, rom, lissabon], extra: ["own"], collections: [mine])
        let (_, made) = try await Self.planAndRun([ConfirmedProposal(proposal: kyoto, decision: Self.new),
                                                  ConfirmedProposal(proposal: rom, decision: .extendExisting("mine")),
                                                  ConfirmedProposal(proposal: lissabon, decision: Self.new)], in: library)
        var adopted = made
        let lisbon = try key(of: lissabon.title, in: adopted)
        adopted.record?.adoptedKeys.insert(lisbon)
        let receipt = PlanReceipt(plan: adopted, inventory: CollectionInventory())
        #expect(receipt.albumsCreated == 1 && receipt.albumsExtended == 1)
        let stack = ResultCoverStack(plan: adopted)
        #expect(stack.albums == .created)
        #expect(stack.cards.map(\.id) == ["planned:" + (try key(of: kyoto.title, in: adopted))], "\(stack.cards.map(\.id))")
        #expect(stack.shown(sharp: allSharp(stack), limit: ResultCoverStack.limit).count <= receipt.albumsCreated)

        // Nothing made verifiably, photos in the user's album and in an adopted one: the user's
        // album alone, as "in einem deiner Alben ergänzt" says.
        let kobe = Self.trip("kobe"), porto = Self.trip("porto")
        let japan = CollectionSnapshot(id: "japan", title: "Japan", assetIDs: ["own2"])
        let other = Self.library([kobe, porto], extra: ["own2"], collections: [japan])
        let (_, second) = try await Self.planAndRun([ConfirmedProposal(proposal: kobe, decision: .extendExisting("japan")),
                                                    ConfirmedProposal(proposal: porto, decision: Self.new)], in: other)
        var found = second
        let portoKey = try key(of: porto.title, in: second)
        found.record?.adoptedKeys.insert(portoKey)
        let foundReceipt = PlanReceipt(plan: found, inventory: CollectionInventory())
        #expect(foundReceipt.albumsCreated == 0 && foundReceipt.albumsExtended == 1)
        let extended = ResultCoverStack(plan: found)
        #expect(extended.albums == .extended && extended.cards.map(\.id) == ["japan"], "\(extended.cards.map(\.id))")
        #expect(extended.shown(sharp: allSharp(extended), limit: ResultCoverStack.limit).count <= foundReceipt.albumsExtended)
    }

    /// The cover the suggestion's card showed comes first, so the stack shows the photos the user
    /// knows from the cards; otherwise the newest photo (Photos keeps the newest on the device).
    @Test func theCardsOwnCoverComesFirst() async throws {
        let kyoto = Self.trip("kyoto", photos: 6)
        let library = Self.library([kyoto])
        let (_, made) = try await Self.planAndRun([ConfirmedProposal(proposal: kyoto, decision: Self.new)], in: library)
        var dates: [AssetID: Date] = [:]
        for index in 1...6 { dates[AssetID("kyoto-\(index)")] = Date(timeIntervalSince1970: Double(index) * 100) }
        #expect(ResultCoverStack(plan: made, dates: dates, covers: [kyoto.id: "kyoto-2"]).cards.first?.candidates.first == "kyoto-2")
        // A cover the album no longer holds is passed over.
        let other = ResultCoverStack(plan: made, dates: dates, covers: [kyoto.id: "elsewhere"])
        #expect(other.cards.first?.candidates.contains("elsewhere") == false)
    }

    /// The same photo never lies on two cards: a country album holds its trips, and each card
    /// tries photos the cards before it do not.
    @Test func aPhotoInTwoAlbumsIsOneCardsCoverOnly() async throws {
        let italy = AlbumProposal(id: AlbumistID("italy"), kind: .placeCollection(.country), title: "Italien",
                                  assetIDs: ["rom-1", "rom-2", "rom-3", "neapel-1"])
        let rom = AlbumProposal(id: AlbumistID("rom"), kind: .trip, title: "Rom", assetIDs: ["rom-1", "rom-2", "rom-3"])
        let library = Self.library([italy, rom])
        let (_, made) = try await Self.planAndRun([ConfirmedProposal(proposal: italy, decision: Self.new),
                                                  ConfirmedProposal(proposal: rom, decision: Self.new)], in: library)
        let stack = ResultCoverStack(plan: made)
        let all = stack.cards.flatMap(\.candidates)
        #expect(Set(all).count == all.count, "a photo is a candidate of two cards: \(stack.cards)")
        // Italy tries all four, so Rome has no photo left that Italy does not try.
        #expect(stack.cards.count == 1)
    }

    /// The same run gives the same stack, whatever order its photos come in.
    @Test func theOrderStaysTheSame() async throws {
        let trips = (0..<6).map { Self.trip("t\($0)", photos: 5) }
        let library = Self.library(trips)
        let (_, made) = try await Self.planAndRun(trips.map { ConfirmedProposal(proposal: $0, decision: Self.new) }, in: library)
        var shuffled = made
        for index in shuffled.steps.indices {
            if case .addAssets(let album, let assets) = shuffled.steps[index].operation {
                shuffled.steps[index].operation = .addAssets(album: album, assets: assets.reversed())
                if let media = shuffled.record?.media[shuffled.steps[index].id] {
                    shuffled.record?.media[shuffled.steps[index].id] = media.reversed()
                }
            }
        }
        #expect(ResultCoverStack(plan: made) == ResultCoverStack(plan: shuffled))
        #expect(ResultCoverStack(plan: made) == ResultCoverStack(plan: made))
    }

    /// What the preview loads ahead while the plan runs is what the result then lays down.
    @Test func whatIsLoadedAheadIsWhatTheResultShows() async throws {
        let trips = (0..<3).map { Self.trip("t\($0)", photos: 4) }
        let mine = CollectionSnapshot(id: "mine", title: "Italien", assetIDs: ["own"])
        let library = Self.library(trips, extra: ["own"], collections: [mine])
        let (planned, made) = try await Self.planAndRun(trips.map { ConfirmedProposal(proposal: $0, decision: Self.new) }, in: library)
        #expect(ResultCoverStack(plan: planned, expected: true) == ResultCoverStack(plan: made))

        let rom = Self.trip("rom")
        let other = Self.library([rom], extra: ["own"], collections: [mine])
        let (extendPlan, extended) = try await Self.planAndRun([ConfirmedProposal(proposal: rom, decision: .extendExisting("mine"))], in: other)
        #expect(ResultCoverStack(plan: extendPlan, expected: true) == ResultCoverStack(plan: extended))
        #expect(ResultCoverStack(plan: extended).albums == .extended)
    }

    /// The covers loaded while the plan ran are kept in the result's own state as they arrive: the
    /// result shows them even when the covers' store was emptied meanwhile (a memory warning, a
    /// moment in the background), and takes the store only for a card nothing was kept for (review
    /// E2 of design wave 2, N3). A kept photo that is no candidate of its card any more (a step the
    /// library did not confirm) is passed over; the order is the stack's.
    @Test func coversKeptAheadOutlastTheStore() async throws {
        let trips = (0..<4).map { Self.trip("t\($0)", photos: 4) }
        let library = Self.library(trips)
        let (_, made) = try await Self.planAndRun(trips.map { ConfirmedProposal(proposal: $0, decision: Self.new) }, in: library)
        let stack = ResultCoverStack(plan: made)
        #expect(stack.cards.count == 4)
        let cards = stack.cards
        let held: [String: AssetID] = [cards[0].id: cards[0].candidates[1], cards[1].id: "not a candidate", cards[3].id: cards[3].candidates[0]]
        let stored: Set<AssetID> = [cards[1].candidates[2], cards[2].candidates[0], cards[2].candidates[1], cards[0].candidates[0]]
        let sharp = stack.sharpPhotos(held: held) { stored.contains($0) }
        #expect(sharp == [cards[0].id: cards[0].candidates[1], cards[1].id: cards[1].candidates[2],
                          cards[2].id: cards[2].candidates[0], cards[3].id: cards[3].candidates[0]])
        #expect(stack.shown(sharp: sharp, limit: 5).map(\.card) == [cards[0].id, cards[1].id, cards[2].id])
        // The store emptied: what was kept stays, in the stack's order.
        let emptied = stack.sharpPhotos(held: held) { _ in false }
        #expect(emptied == [cards[0].id: cards[0].candidates[1], cards[3].id: cards[3].candidates[0]])
        #expect(stack.shown(sharp: emptied, limit: 5) == [ResultCoverStack.Shown(card: cards[0].id, photo: cards[0].candidates[1]),
                                                          ResultCoverStack.Shown(card: cards[3].id, photo: cards[3].candidates[0])])
        // Nothing kept, nothing stored: no stack.
        #expect(stack.sharpPhotos(held: [:]) { _ in false }.isEmpty)
    }

    // MARK: Skipping the show

    /// The show's counter ends on the photos the receipt counts ("mit 342 Fotos"), also when the
    /// library did not confirm a step: skipping the show or watching it to the end leaves the same
    /// numbers. `appliedAssets` counted the planned photos of such a step.
    @Test func theShowEndsOnTheReceiptsCount() async throws {
        let kyoto = Self.trip("kyoto", photos: 4), rom = Self.trip("rom", photos: 2)
        let library = Self.library([kyoto, rom])
        let (_, made) = try await Self.planAndRun([ConfirmedProposal(proposal: kyoto, decision: Self.new),
                                                  ConfirmedProposal(proposal: rom, decision: Self.new)], in: library)
        let receipt = PlanReceipt(plan: made, inventory: CollectionInventory())
        #expect(made.confirmedAddedMedia.count == receipt.photosAdded)
        #expect(receipt.photosAdded == 6)

        // A step whose outcome the library did not confirm.
        var unclear = made
        let add = try #require(unclear.steps.lastIndex { if case .addAssets = $0.operation { true } else { false } })
        let step = unclear.steps[add].id
        unclear.record?.unverified.insert(step)
        unclear.record?.media[step] = nil
        let unclearReceipt = PlanReceipt(plan: unclear, inventory: CollectionInventory())
        #expect(unclear.confirmedAddedMedia.count == unclearReceipt.photosAdded)
        #expect(unclear.appliedAssets.count > unclearReceipt.photosAdded, "the old count already agreed")

        // A plan of an older version, without a journal: its succeeded steps.
        var older = made
        older.record = nil
        #expect(older.confirmedAddedMedia.count == PlanReceipt(plan: older, inventory: CollectionInventory()).photosAdded)
    }
}

/// How the covers lie (draft E3): the main cover upright in the middle and on top, the others
/// turned a little to each side behind it, a white edge and a soft shadow (drawn by the app).
@Suite("Result cover fan")
struct ResultCoverFanTests {
    /// One slot per cover, the main cover first, upright and on top.
    @Test func theMainCoverIsInTheMiddleAndOnTop() {
        for count in [1, 2, 3, 5] {
            let slots = ResultCoverFan.slots(count)
            #expect(slots.count == count)
            let main = slots[0]
            #expect(slots.dropFirst().allSatisfy { $0.layer < main.layer }, "\(count)")
            if count != 2 {
                #expect(main.angle == 0 && main.x == 0 && main.y == 0, "\(count)")
            }
        }
        // As in the draft: five covers turned 7° and 14° to each side.
        #expect(ResultCoverFan.slots(5).map(\.angle) == [0, -7, 7, -14, 14])
        // Four are laid as three.
        #expect(ResultCoverFan.count(4) == 3)
        #expect(ResultCoverFan.count(7) == 5)
        #expect(ResultCoverFan.slots(4) == ResultCoverFan.slots(3))
    }

    /// The covers lie down from the back to the front: the main cover last.
    @Test func theMainCoverLiesDownLast() {
        for count in [1, 2, 3, 5] {
            let order = ResultCoverFan.layingOrder(count)
            #expect(Set(order) == Set(0..<count))
            #expect(order.last == 0, "\(count): \(order)")
            let layers = order.map { ResultCoverFan.slots(count)[$0].layer }
            #expect(layers == layers.sorted(), "\(count): \(layers)")
        }
    }

    /// The fan is balanced around the middle of the screen.
    @Test func theFanIsBalanced() {
        for count in [1, 3, 5] {
            let box = ResultCoverFan.bounds(count)
            #expect(abs(box.minX + box.maxX) < 0.001, "\(count): \(box)")
        }
        let pair = ResultCoverFan.bounds(2)
        #expect(abs(pair.minX + pair.maxX) < 8, "\(pair)")
    }

    /// The success tap comes as the main cover lies down: the covers one after another, the main
    /// cover last, at most 0.74 s after the moment starts (five covers), 0.35 s with Reduce Motion,
    /// at once with the symbol. The screen lets the tap go after `successDeadline` whatever happens
    /// (review E of design wave 2, finding 1: it waited for Photos without a limit).
    @Test func theMainCoverLiesWithinTheDeadline() {
        #expect(ResultCoverFan.successDeadline == 1.5)
        for count in 0...7 {
            for calm in [false, true] {
                let settle = ResultCoverFan.settleTime(count: count, calm: calm)
                #expect(settle >= 0 && settle < ResultCoverFan.successDeadline, "\(count), calm \(calm): \(settle)")
            }
        }
        #expect(ResultCoverFan.settleTime(count: 0, calm: false) == 0, "the symbol: the tap at once")
        #expect(ResultCoverFan.settleTime(count: 0, calm: true) == 0)
        #expect(abs(ResultCoverFan.settleTime(count: 5, calm: false) - (4 * ResultCoverFan.layingStep + ResultCoverFan.lastFall)) < 1e-9)
        #expect(ResultCoverFan.settleTime(count: 1, calm: false) == ResultCoverFan.lastFall)
        #expect(ResultCoverFan.settleTime(count: 5, calm: true) == ResultCoverFan.fadeIn)
        // Four lie as three.
        #expect(ResultCoverFan.settleTime(count: 4, calm: false) == ResultCoverFan.settleTime(count: 3, calm: false))
    }

    /// Five covers fit across a 6.1" iPhone at their full size; on the 4.7" iPhone they get a
    /// little smaller, and where the screen is short they shrink, but never below six tenths:
    /// below that the screen scrolls, and the buttons under the stack keep their room (review E,
    /// finding 8).
    @Test func theFanFitsTheScreen() {
        let five = ResultCoverFan.size(5)
        #expect(five.width > 343 && five.width <= 361, "\(five)")
        #expect(ResultCoverFan.scale(count: 5, width: 361, height: 1000) == 1)
        let small = ResultCoverFan.scale(count: 5, width: 343, height: 1000)
        #expect(small < 1 && small > 0.9)
        #expect(ResultCoverFan.scale(count: 3, width: 343, height: 100) < 1)
        #expect(ResultCoverFan.scale(count: 3, width: 343, height: 10) == ResultCoverFan.minimumScale)
        #expect(ResultCoverFan.minimumScale == 0.6)
        #expect(ResultCoverFan.scale(count: 5, width: 100, height: 100) == 0.6)
        // One cover is the card's own size.
        #expect(ResultCoverFan.size(1).width == ResultCoverFan.cardWidth)
        #expect(ResultCoverFan.size(1).height == ResultCoverFan.cardHeight)
    }

    /// Until the screen's room is measured the fan is laid out at its smallest size, so once the
    /// room is known it can only grow: the count and the buttons below it never jump up as the
    /// result comes (on the 4.7" iPhone it stays as it was laid out; review E2 of design wave 2,
    /// N7).
    @Test func theFanOnlyGrowsOnceTheRoomIsKnown() {
        for count in [1, 2, 3, 5] {
            let unknown = ResultCoverFan.scale(count: count, width: 361, height: nil)
            #expect(unknown == ResultCoverFan.minimumScale, "\(count)")
            for width in [100.0, 343, 361, 600] {
                #expect(ResultCoverFan.scale(count: count, width: width, height: nil) == unknown, "\(count), \(width)")
                for height in [0.0, 10, 100, 150, 200, 1000] {
                    #expect(ResultCoverFan.scale(count: count, width: width, height: height) >= unknown, "\(count), \(width), \(height)")
                }
            }
        }
        // The 4.7" iPhone at the default size: less room than five covers take at the smallest
        // size (review E2: 193 pt drawn, 116 pt at the smallest), so the fan stays as it was laid out.
        #expect(ResultCoverFan.scale(count: 5, width: 343, height: 110) == ResultCoverFan.minimumScale)
    }
}

/// Which covers of the stack load next while the plan runs (draft E3; review E2 of design wave 2,
/// N3): a few cards side by side in the stack's order, a card Photos did not answer for makes way
/// for the next and is tried again after them, and only cards that may still lie on the stack
/// load. The app loads each through `CoverLoader` (sharp, from the device) and keeps what arrives.
@Suite("Result cover prefetch")
struct ResultCoverPrefetchTests {
    typealias Prefetch = ResultCoverPrefetch

    static func cards(_ count: Int) -> [String] {
        (0..<count).map { "card\($0)" }
    }

    /// Starts what may start now.
    static func start(_ loading: inout Prefetch) -> [Prefetch.Start] {
        var started: [Prefetch.Start] = []
        while let next = loading.next() { started.append(next) }
        return started
    }

    static func answer(_ loading: inout Prefetch, _ card: String, _ answer: Prefetch.Answer) {
        loading.record(Prefetch.Arrival(card: card, answer: answer))
    }

    /// Three cards load side by side, in the stack's order (review E2, N3: one after another, a
    /// card Photos did not answer for held up every card after it).
    @Test func theCoversLoadSideBySide() {
        #expect(Prefetch.together == 3)
        var loading = Prefetch(cards: Self.cards(8), limit: 5)
        let first = Self.start(&loading)
        #expect(first.map(\.card) == ["card0", "card1", "card2"])
        #expect(first.allSatisfy { !$0.again })
        #expect(loading.loading == 3)
        let fourth = loading.next()
        #expect(fourth == nil, "no fourth while three load")
        Self.answer(&loading, "card1", .sharp("p1"))
        let then = Self.start(&loading)
        #expect(then.map(\.card) == ["card3"])
        #expect(!loading.isDecided)
    }

    /// A card Photos did not answer for makes way for the next ones and is tried again after
    /// them: the stack does not wait on it, and it still gets its turn while there is time.
    @Test func aCardWithoutAnswerMakesWayAndComesBack() {
        var loading = Prefetch(cards: Self.cards(6), limit: 5)
        _ = Self.start(&loading)
        Self.answer(&loading, "card0", .noAnswer)
        let next = Self.start(&loading)
        #expect(next == [Prefetch.Start(card: "card3", again: false)])
        Self.answer(&loading, "card1", .sharp("p1"))
        let after = Self.start(&loading)
        #expect(after == [Prefetch.Start(card: "card4", again: false)])
        Self.answer(&loading, "card2", .sharp("p2"))
        // Cards 0 to 4 may still lie on the stack: card 5 waits, card 0 comes back.
        let back = Self.start(&loading)
        #expect(back == [Prefetch.Start(card: "card0", again: true)])
        Self.answer(&loading, "card3", .sharp("p3"))
        Self.answer(&loading, "card4", .sharp("p4"))
        #expect(!loading.isDecided, "card 0 may still be the main cover")
        Self.answer(&loading, "card0", .sharp("p0"))
        #expect(loading.isDecided)
        #expect(loading.sharp == ["card0": "p0", "card1": "p1", "card2": "p2", "card3": "p3", "card4": "p4"])
        let done = Self.start(&loading)
        #expect(done.isEmpty)
    }

    /// A card is tried at most `tries` times, as a card's own cover; then the stack goes on
    /// without it.
    @Test func aCardIsTriedAFewTimesAtMost() {
        #expect(Prefetch.tries == 4)
        var loading = Prefetch(cards: Self.cards(1), limit: 5)
        var starts: [Prefetch.Start] = []
        while let next = loading.next() {
            starts.append(next)
            Self.answer(&loading, next.card, .noAnswer)
        }
        let again = Array(repeating: Prefetch.Start(card: "card0", again: true), count: 3)
        #expect(starts == [Prefetch.Start(card: "card0", again: false)] + again)
        #expect(loading.isDecided)
        #expect(loading.sharp.isEmpty)
    }

    /// Only cards that may still lie on the stack load: once the cards before one have, or may
    /// still get, as many sharp covers as the stack holds, it waits; a card without a sharp photo
    /// on the device makes room for the next. The stack is decided in its own order.
    @Test func onlyCardsThatMayLieOnTheStackLoad() {
        var loading = Prefetch(cards: Self.cards(7), limit: 3)
        let first = Self.start(&loading)
        #expect(first.map(\.card) == ["card0", "card1", "card2"])
        Self.answer(&loading, "card2", .sharp("p2"))
        Self.answer(&loading, "card1", .sharp("p1"))
        let waiting = Self.start(&loading)
        #expect(waiting.isEmpty, "cards 0, 1 and 2 may fill the stack")
        Self.answer(&loading, "card0", .noSharpPhoto)
        #expect(!loading.isDecided)
        let next = Self.start(&loading)
        #expect(next.map(\.card) == ["card3"])
        Self.answer(&loading, "card3", .sharp("p3"))
        #expect(loading.isDecided)
        #expect(loading.sharp == ["card1": "p1", "card2": "p2", "card3": "p3"])
        // An answer nobody asked for changes nothing.
        Self.answer(&loading, "card6", .sharp("p6"))
        #expect(loading.sharp["card6"] == nil)
    }

    /// Nothing to load, or no room on the stack: decided at once.
    @Test func nothingToLoad() {
        var empty = Prefetch(cards: [], limit: 5)
        let none = empty.next()
        #expect(empty.isDecided)
        #expect(none == nil)
        var full = Prefetch(cards: Self.cards(3), limit: 0)
        let nothing = full.next()
        #expect(full.isDecided)
        #expect(nothing == nil)
    }
}
