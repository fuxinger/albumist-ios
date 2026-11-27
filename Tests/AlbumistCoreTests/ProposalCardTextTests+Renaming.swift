import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// Renaming or moving the user's album (`ProposalCardTextTests`).
extension ProposalCardTextTests {
    // MARK: Renaming or moving the user's album ("Ansehen …")

    /// "Sommer" in the folder "Reisen" holds all ten photos of "Gardasee, Juli 2024"; the folder
    /// "Zuhause" is beside "Reisen".
    static func garda() -> (AlbumProposal, CollectionInventory) {
        let proposal = AlbumProposal(id: AlbumistID("trip-garda"), kind: .trip, title: "Gardasee, Juli 2024", folderPath: ["Reisen"],
                                     assetIDs: ids("g", 10), reliability: .certain)
        let travel = CollectionSnapshot(id: "reisen", title: "Reisen", kind: .folder, childIDs: ["sommer"])
        let home = CollectionSnapshot(id: "zuhause", title: "Zuhause", kind: .folder)
        let album = CollectionSnapshot(id: "sommer", title: "Sommer", parentID: "reisen", assetIDs: ids("g", 10))
        return (proposal, CollectionInventory([travel, home, album]))
    }

    /// What the plan does to the user's albums with `decision`, as its preview lists it:
    /// "rename", "move", "add".
    static func planned(_ proposal: AlbumProposal, _ decision: ProposalDecision, _ inventory: CollectionInventory,
                        root: String = "") -> Set<String> {
        let plan = OrganizationPlanner(rootFolderTitle: root)
            .makePlan(from: [ConfirmedProposal(proposal: proposal, decision: decision)], inventory: inventory)
        var done: Set<String> = []
        for step in plan.steps {
            switch step.operation {
            case .renameCollection: done.insert("rename")
            case .moveCollection: done.insert("move")
            case .addAssets: done.insert("add")
            default: break
            }
        }
        return done
    }

    /// A decision that renames the user's album and adds nothing (the album holds every photo, or
    /// the decision adds none) is no "Schon in deinem Album": the card says the album gets a new
    /// name, and its title is that name, as the plan renames it.
    @Test func renamingTheUsersAlbumSaysSo() {
        let (proposal, inventory) = Self.garda()
        for extend in [false, true] {
            let decision = ProposalDecision.renameExisting("sommer", newTitle: "Gardasee ", extend: extend)
            let card = Self.card(proposal, decision: decision, inventory: inventory)
            #expect(card.outcome == .renames(album: "sommer", from: "Sommer", to: "Gardasee"))
            #expect(card.title == "Gardasee")
            #expect(card.subtitle == "Benennt dein Album „Sommer“ um")
            #expect(card.status == .renames(album: "Sommer"))
            #expect(card.action == .look)
            #expect(!card.needsLook)
            #expect(card.accessibilityLabel == "Gardasee, Benennt dein Album „Sommer“ um")
            #expect(Self.planned(proposal, decision, inventory) == ["rename"])
        }
        let english = Self.card(proposal, decision: .renameExisting("sommer", newTitle: "Gardasee", extend: false),
                                inventory: inventory, words: .english)
        #expect(english.subtitle == "Renames your album “Sommer”")
        // Its own name again: the plan changes nothing.
        let same = ProposalDecision.renameExisting("sommer", newTitle: " Sommer", extend: false)
        #expect(Self.card(proposal, decision: same, inventory: inventory).outcome == .alreadyIn(album: "sommer", title: "Sommer"))
        #expect(Self.planned(proposal, same, inventory).isEmpty)
    }

    /// A decision that moves the user's album into another folder and adds nothing says so; into
    /// the folder it is in already, nothing changes. The folder is the one the plan finds or
    /// makes, below the root folder when there is one.
    @Test func movingTheUsersAlbumSaysSo() {
        let (proposal, inventory) = Self.garda()
        let decision = ProposalDecision.moveExisting("sommer", folderPath: ["Zuhause"], extend: false)
        let card = Self.card(proposal, decision: decision, inventory: inventory)
        #expect(card.outcome == .moves(album: "sommer", title: "Sommer", folderPath: ["Zuhause"]))
        #expect(card.title == "Gardasee, Juli 2024")
        #expect(card.subtitle == "Verschiebt dein Album „Sommer“")
        #expect(card.status == .moves(album: "Sommer"))
        #expect(card.action == .look)
        #expect(!card.needsLook)
        #expect(Self.planned(proposal, decision, inventory) == ["move"])
        #expect(Self.card(proposal, decision: decision, inventory: inventory, words: .english).subtitle == "Moves your album “Sommer”")
        // Where it is already: nothing changes, also with nothing to add.
        let stays = ProposalDecision.moveExisting("sommer", folderPath: ["Reisen"], extend: true)
        #expect(Self.card(proposal, decision: stays, inventory: inventory).outcome == .alreadyIn(album: "sommer", title: "Sommer"))
        #expect(Self.planned(proposal, stays, inventory).isEmpty)
        // Below the root folder "Albumist", which is not there yet: its "Reisen" is another folder.
        let below = Self.card(proposal, decision: stays, inventory: inventory, root: "Albumist")
        #expect(below.outcome == .moves(album: "sommer", title: "Sommer", folderPath: ["Albumist", "Reisen"]))
        #expect(Self.planned(proposal, stays, inventory, root: "Albumist") == ["move"])
        // Out of its folder, to the top of the albums.
        let top = ProposalDecision.moveExisting("sommer", folderPath: [], extend: false)
        #expect(Self.card(proposal, decision: top, inventory: inventory).outcome == .moves(album: "sommer", title: "Sommer", folderPath: []))
        #expect(Self.planned(proposal, top, inventory) == ["move"])
    }

    /// With photos to add, the card says where they go, as for "Ergänzen …".
    @Test func renamingOrMovingWithPhotosToAddSaysWhereTheyGo() {
        let (proposal, full) = Self.garda()
        var inventory = full
        inventory.upsert(CollectionSnapshot(id: "sommer", title: "Sommer", parentID: "reisen", assetIDs: Self.ids("g", 6)))
        let moved = ProposalDecision.moveExisting("sommer", folderPath: ["Zuhause"], extend: true)
        #expect(Self.card(proposal, decision: moved, inventory: inventory).outcome == .addsTo(album: "sommer", title: "Sommer", newPhotos: 4))
        #expect(Self.planned(proposal, moved, inventory) == ["move", "add"])
        let unchanged = ProposalDecision.moveExisting("sommer", folderPath: ["Zuhause"], extend: false)
        #expect(Self.card(proposal, decision: unchanged, inventory: inventory).outcome
                == .moves(album: "sommer", title: "Sommer", folderPath: ["Zuhause"]))
    }
}
