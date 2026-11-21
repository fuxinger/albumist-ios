import SwiftUI
import AlbumistCore

/// Every album Albumist created or extended ("Alle 12" beside "Von Albumist" in the tab "Alben",
/// design 5C), newest change first, as photo tiles like the shelf above it. Each one can be undone
/// from its long press or from "…" in the album (decision 17.11.): Albumist removes only the
/// photos it added itself and deletes an album only if it created it and nothing else is in it
/// (`albumUndo`).
struct ManagedAlbumsView: View {
    @Environment(AppModel.self) private var model
    @State private var viewing: PhotoViewer.Start?
    @State private var undoing: ManagedAlbumState?

    var body: some View {
        let albums = AlbumTabSections(inventory: model.inventory, managed: model.managedAlbums, history: model.history,
                                      undone: model.undonePlans).albumistAlbums
        Group {
            if albums.isEmpty {
                ContentUnavailableView("Noch keine Alben", systemImage: "rectangle.stack",
                                       description: Text("Hier erscheinen Alben, die Albumist angelegt oder ergänzt hat."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                        AlbumGrid {
                            ForEach(albums) { album in
                                AlbumTile(album: album.collection, managed: album.state,
                                          viewPhotos: { viewing = $0 }, undo: { undoing = $0 })
                            }
                        }
                        footer
                    }
                    .padding(.vertical, Theme.Spacing.l)
                }
            }
        }
        .background(Theme.background)
        // Also albums Albumist only added to (design review N9): "Von Albumist" as above the shelf.
        .navigationTitle("Von Albumist")
        .navigationBarTitleDisplayMode(.inline)
        .albumUndo($undoing)
        .fullScreenCover(item: $viewing) { start in
            PhotoViewer(ids: start.ids, current: start.id, showsInfo: true)
        }
    }

    /// How to undo, and where the albums are in Photos (iOS opens Photos, not one album).
    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Self.howToUndo
            Self.place(root: model.settings.rootFolderTitle)
        }
        .font(.footnote)
        .foregroundStyle(.noteText)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Theme.Spacing.l)
    }

    /// How to undo one of Albumist's albums: here, and behind "Mehr erfahren" under the shelf.
    static var howToUndo: Text {
        Text("Halte ein Album gedrückt oder tippe im Album auf „…“, um Albumists Änderungen daran rückgängig zu machen. Fotos, die du selbst hinzugefügt hast, bleiben drin.")
    }

    /// Where Albumist's new albums are in Photos: at the top level, or in the folder set for them
    /// (`root`, the settings' folder for new albums).
    static func place(root: String) -> Text {
        let root = root.trimmingCharacters(in: .whitespaces)
        return root.isEmpty ? Text("Neue Alben liegen in Fotos unter Sammlungen › Alben.")
                            : Text("Neue Alben liegen in Fotos im Ordner „\(root)“.")
    }
}

extension View {
    /// "Rückgängig machen" for one of Albumist's albums on this screen: set `asked` to the
    /// album's record (the long press on its tile, "…" in the album), and `AlbumUndo` takes it
    /// from there.
    func albumUndo(_ asked: Binding<ManagedAlbumState?>) -> some View {
        modifier(AlbumUndo(asked: asked))
    }
}

/// The undo of one album of Albumist's, the same wherever it is offered (decision 5C: "an jedem
/// Album"; 17.11.: "…" in the album, the long press as a shortcut). First the photo access is
/// asked for (as every undo button does, second look at S2), then the user confirms, told that
/// iOS asks next when the album is deleted (review 18.11., P3-07). The removal is made from what
/// Photos holds then and shown in the usual preview, pushed onto this screen's stack
/// (`AppScreen`; with `navigationDestination(isPresented:)` the preview was drawn 502 times in a
/// 5.9 s stall, UI run 44066730498, device test 08). A removal ready while another tab was chosen
/// is shown when this tab shows again, if it is still current then (`PlanRequest`); after Back
/// or elsewhere on this stack it is dropped. Once the removal ran, the suggestions behind the
/// album are not offered again.
struct AlbumUndo: ViewModifier {
    @Binding var asked: ManagedAlbumState?
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator: Navigator?
    /// The album the confirmation asks about, once the photo access is known to be full.
    @State private var confirming: Confirming?
    /// A removal that was ready while another tab was chosen: shown when this tab shows again.
    @State private var waiting: Ready?
    /// The removal in the preview and the suggestions behind its album.
    @State private var removing: Removing?
    @State private var nothingToDo = false

    private struct Ready {
        let plan: ChangePlan
        let state: ManagedAlbumState
        let request: PlanRequest
    }

    private struct Removing {
        let plan: AlbumistID
        let sources: Set<AlbumistID>
    }

    /// The album asked about and what its undo does, worked out at the tap.
    private struct Confirming {
        let state: ManagedAlbumState
        let effect: AlbumTabSections.UndoEffect
    }

    func body(content: Content) -> some View {
        content
            .onChange(of: asked) { _, state in
                guard let state else { return }
                asked = nil
                Task { await confirm(state) }
            }
            .confirmationDialog(
                confirming.map { Text("„\($0.state.lastKnownTitle)“ rückgängig machen?") } ?? Text(""),
                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                titleVisibility: .visible,
                presenting: confirming
            ) { question in
                // The menu's line says the same (`AlbumUndoMenuItem`): an album Albumist created
                // goes while nothing else is in it; from any other only Albumist's photos come out.
                Button(question.effect.deletesAlbum ? "Album entfernen" : "Albumists Fotos herausnehmen", role: .destructive) {
                    prepare(question.state)
                }
            } message: { question in
                if question.effect.deletesAlbum {
                    // iOS asks after the preview before it deletes, and this says so first (review
                    // 18.11., P3-07). The removal is made from what Photos holds after the tap: an
                    // album the user put photos into meanwhile stays with them.
                    DeleteQuestionNote.message(Text("Albumist hat dieses Album angelegt. Es wird gelöscht. Hast du selbst Fotos hineingelegt, bleibt das Album mit diesen Fotos bestehen."),
                                               deletes: true)
                } else {
                    let count = question.effect.photosTakenOut
                    Text("Die \(count) \(count.formatted()) Fotos, die Albumist hinzugefügt hat, werden aus dem Album genommen. Alles andere bleibt, wie es ist.")
                }
            }
            .alert("Nichts zu tun", isPresented: $nothingToDo) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Die Fotos von Albumist sind schon nicht mehr in diesem Album.")
            }
            .onAppear { showWaiting() }
            // The tab shows again (`Navigator.appearances`): a removal that waited is shown now.
            .onChange(of: navigator?.appearances) { showWaiting() }
            // Only the removal this screen showed: another plan that ends meanwhile says nothing
            // about it (the preview left without "Entfernen" keeps its suggestions).
            .onChange(of: model.execution.finished) { _, finished in
                guard let finished, let removed = removing, finished.id == removed.plan else { return }
                removing = nil
                Task { for source in removed.sources { await model.forgetProposal(source) } }
            }
    }

    /// Asks for the full photo access, then for the confirmation, which says what the undo does:
    /// worked out from the album as the list holds it, by the rule the menu's line follows
    /// (`AlbumTabSections.undoEffect`), so no removal is built for the question. When that
    /// finds nothing of Albumist's left, Albumist looks in Photos at once (`prepare`): the removal
    /// shows in the preview if the list was behind, "Nichts zu tun" otherwise.
    private func confirm(_ state: ManagedAlbumState) async {
        guard await model.changesHaveFullAccess() else { return }
        let effect = AlbumTabSections.undoEffect(state, album: model.inventory[state.albumID])
        if effect.doesSomething {
            confirming = Confirming(state: state, effect: effect)
        } else {
            prepare(state)
        }
    }

    /// Makes the removal from what Photos holds now (`AppModel.removalPlan`, after the check for
    /// changes the user made there); "Nichts zu tun" when nothing of Albumist's is left in it.
    private func prepare(_ state: ManagedAlbumState, attempt: Int = 1) {
        confirming = nil
        waiting = nil
        let request = PlanRequest(model: model, navigator: navigator)
        Task {
            guard let removal = await model.removalPlan(for: state) else {
                if navigator?.isShowing(request.mark) == true { nothingToDo = true }
                return
            }
            offer(Ready(plan: removal, state: state, request: request), attempt: attempt)
        }
    }

    /// A removal that is ready, or that waited for this tab: shown if it is still current, kept
    /// while another tab is chosen, made again once when the album list changed meanwhile (a
    /// second change says Albumist is busy), dropped when the user went elsewhere on this stack.
    private func offer(_ ready: Ready, attempt: Int) {
        switch ready.request.verdict(model: model, navigator: navigator) {
        case .show:
            if Navigator.push(.prebuiltPlan(PlanToken(ready.plan)), on: navigator, ifStill: ready.request.mark) == .pushed {
                removing = Removing(plan: ready.plan.id, sources: ready.state.allSourceIDs)
            }
        case .wait:
            waiting = ready
        case .gone:
            break
        case .busy:
            model.message = .busy
        case .stale:
            if attempt > 1 {
                model.message = .busy
            } else {
                prepare(ready.state, attempt: attempt + 1)
            }
        }
    }

    /// The tab shows again: a removal that was ready meanwhile is shown now.
    private func showWaiting() {
        guard let ready = waiting, navigator?.showing == true else { return }
        waiting = nil
        offer(ready, attempt: 1)
    }
}
