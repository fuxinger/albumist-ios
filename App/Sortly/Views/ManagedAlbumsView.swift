import SwiftUI
import SortlyCore

/// Albums Albumist created or extended. Each one can be taken back: Albumist removes only the
/// photos it added itself and deletes an album only if it created it and nothing else is in it.
struct ManagedAlbumsView: View {
    @Environment(AppModel.self) private var model
    @State private var pending: ManagedAlbumState?
    /// The removal preview is pushed onto the stack's path (`AppScreen`). With
    /// `navigationDestination(isPresented:)` it was drawn 502 times in a 5.9 s stall (UI run
    /// 44066730498, device test 08).
    @Environment(Navigator.self) private var navigator: Navigator?
    /// On screen: a removal plan that is ready after Back is not pushed. This screen opens only
    /// in the settings sheet, where no other tab can be chosen, so a plan that cannot be pushed
    /// at once is not kept (`Navigator.Outcome.waiting` counts as not pushed).
    @State private var visible = false
    /// The suggestions behind the album being removed; they are not offered again afterwards.
    @State private var removingSources: Set<SortlyID> = []
    @State private var nothingToDo = false

    var body: some View {
        List {
            if model.managedAlbums.isEmpty {
                ContentUnavailableView("Noch keine Alben", systemImage: "rectangle.stack",
                                       description: Text("Hier erscheinen Alben, die Albumist angelegt oder ergänzt hat."))
            } else {
                Section {
                    ForEach(model.managedAlbums, id: \.albumID) { state in
                        Button { pending = state } label: { row(state) }
                            .foregroundStyle(.primary)
                    }
                } footer: {
                    Text("Tippe auf ein Album, um Albumists Änderungen daran zurückzunehmen. Fotos, die du selbst hinzugefügt hast, bleiben drin. Deine Originale bleiben immer in der Mediathek.")
                }
            }
        }
        // Also albums Albumist only added to (design review N9).
        .navigationTitle("Alben von Albumist")
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            pending.map { Text("„\($0.lastKnownTitle)“ zurücknehmen?") } ?? Text(""),
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible,
            presenting: pending
        ) { state in
            Button(state.createdBySortly ? "Album entfernen" : "Albumists Fotos herausnehmen", role: .destructive) {
                // Chosen in this screen's dialog, so the screen is showing, whatever a swipe
                // back that was called off did to `visible`.
                visible = true
                Task { await prepare(state) }
            }
        } message: { state in
            if state.createdBySortly {
                Text("Albumist hat dieses Album angelegt. Es wird gelöscht, die Fotos bleiben in deiner Mediathek. Hast du selbst Fotos hineingelegt, bleibt das Album mit diesen Fotos bestehen.")
            } else {
                Text("Die \(state.addedBySortly.count) Fotos, die Albumist hinzugefügt hat, werden aus dem Album genommen. Alles andere bleibt, wie es ist.")
            }
        }
        .alert("Nichts zu tun", isPresented: $nothingToDo) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Die Fotos von Albumist sind schon nicht mehr in diesem Album.")
        }
        .onChange(of: model.execution.finished) { _, finished in
            guard finished != nil, !removingSources.isEmpty else { return }
            let sources = removingSources
            removingSources = []
            Task { for source in sources { await model.forgetProposal(source) } }
        }
    }

    private func row(_ state: ManagedAlbumState) -> some View {
        HStack(spacing: Theme.Spacing.m) {
            IconTile(systemName: state.createdBySortly ? "rectangle.stack.badge.plus" : "plus.rectangle.on.rectangle", tint: Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.lastKnownTitle).font(.body.weight(.medium))
                Group {
                    if state.createdBySortly {
                        Text("Neu angelegt · \(state.addedBySortly.count) Fotos von Albumist")
                    } else {
                        Text("Ergänzt · \(state.addedBySortly.count) Fotos von Albumist")
                    }
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Änderungen von Albumist zurücknehmen"))
    }

    private func prepare(_ state: ManagedAlbumState) async {
        pending = nil
        let before = navigator?.mark
        guard let removal = await model.removalPlan(for: state) else {
            if visible { nothingToDo = true }
            return
        }
        if Navigator.push(.prebuiltPlan(PlanToken(removal)), on: navigator, ifStill: before, visible: visible) == .pushed {
            removingSources = state.allSourceIDs
        }
    }
}
