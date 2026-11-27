import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// Which photos each album of the result's stack tries (`ResultCoverStackTests`).
extension ResultCoverStackTests {
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
}
