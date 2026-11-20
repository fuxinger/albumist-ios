import SwiftUI
import SortlyCore
import SortlyEngine

/// Inbox (prompt §6): the library split by organization state, with ignore.
struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @State private var bucket: InboxBucket = .unorganized
    @State private var selecting = false
    @State private var selection: Set<AssetID> = []
    /// A tap opens the photo large, its details behind "i" (design review W12).
    @State private var viewing: PhotoViewer.Start?
    /// The photo zooms out of its thumbnail and back into it.
    @Namespace private var zoom
    @State private var addingToAlbum: [AssetID]?
    /// Thumbnails shown so far; more on request, so large libraries stay smooth and every
    /// photo can still be reached.
    @State private var shown = Self.page
    @Environment(\.dynamicTypeSize) private var typeSize

    private static let page = 3_000

    private static let buckets: [InboxBucket] = [.unorganized, .suggestions, .uncertain, .organized, .ignored, .all]

    var body: some View {
        let _ = MainThreadWatch.shared.count("library body")
        // Made off the main thread (`AppModel.libraryBuckets`); `nil` only before the first pass.
        let members = model.libraryBuckets?[bucket]
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                bucketPicker
                if let members {
                    content(members)
                } else {
                    // The first pass over all photos (a moment in a very large library). Not
                    // "Alles sortiert" or "0 Fotos": that would not be true yet.
                    HStack(spacing: Theme.Spacing.s) {
                        ProgressView()
                            .accessibilityHidden(true)
                        Text("Fotos werden zusammengestellt …")
                    }
                    .font(.footnote)
                    .foregroundStyle(.noteText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("library.preparing")
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .background(Theme.background)
        .onAppear { model.showLibraryBuckets() }
        .onDisappear { model.hideLibraryBuckets() }
        .navigationTitle("Mediathek")
        .toolbar {
            if bucket != .suggestions {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selecting ? "Fertig" : "Auswählen") {
                        withAnimation {
                            selecting.toggle()
                            selection = []
                        }
                    }
                }
            }
            if selecting {
                selectionActions
            }
        }
        // While selecting, the tab bar goes and the actions are in the system bottom bar, as in
        // Photos (review P3-01 = G3-04: a floating bar of its own sat above the tab bar).
        .toolbarVisibility(selecting ? .hidden : .automatic, for: .tabBar)
        .safeAreaInset(edge: .bottom) { IgnoreUndoBar() }
        .animation(.snappy, value: model.lastIgnored)
        .fullScreenCover(item: $viewing) { start in
            PhotoViewer(ids: start.ids, current: start.id, showsInfo: true)
                .navigationTransition(.zoom(sourceID: start.id, in: zoom))
        }
        .sheet(isPresented: Binding(get: { addingToAlbum != nil }, set: { if !$0 { addingToAlbum = nil } })) {
            AddToAlbumSheet(assets: addingToAlbum ?? []) {
                // Animated like the other ways out, so the tab bar does not snap back.
                withAnimation {
                    selection = []
                    selecting = false
                }
            }
        }
        .refreshable { await model.refreshDerived() }
    }

    /// One area's count and its photos (or its suggestions).
    @ViewBuilder
    private func content(_ members: [LibraryBuckets.Item]) -> some View {
        if bucket == .suggestions {
            // Numbers as plural strings (design review W5: "1 Fotos und Videos").
            Text("\(model.openProposals.count) Vorschläge für \(members.count) \(members.count.formatted()) Fotos und Videos")
                .font(.footnote).foregroundStyle(.noteText).monospacedDigit()
        } else {
            Text("\(members.count) \(members.count.formatted()) Fotos und Videos")
                .font(.footnote).foregroundStyle(.noteText).monospacedDigit()
        }

        if bucket == .suggestions {
            // Photos with a suggestion: show the suggestions themselves, ready to open.
            proposalList
        } else if members.isEmpty {
            ContentUnavailableView(emptyTitle, systemImage: "photo.on.rectangle",
                                   description: Text(emptyDescription))
        } else {
            grid(members)
            if members.count > shown {
                // The next photos load by themselves when the end of the grid comes
                // into view (design review N10: a button every 3,000 photos).
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.m)
                    .accessibilityLabel(Text("Weitere Fotos werden geladen"))
                    .onScrollVisibilityChange(threshold: 0.1) { visible in
                        if visible { shown += Self.page }
                    }
                    .accessibilityLabel(Text("Weitere Fotos werden geladen"))
                    .accessibilityIdentifier("library.loadingMore")
            }
        }
    }

    @ViewBuilder
    private var proposalList: some View {
        let open = model.openProposals.sorted { ($0.assetIDs.count, $1.title) > ($1.assetIDs.count, $0.title) }
        if open.isEmpty {
            ContentUnavailableView("Keine offenen Vorschläge", systemImage: "checkmark.circle",
                                   description: Text("Alle Vorschläge sind entschieden."))
        } else {
            VStack(spacing: 0) {
                ForEach(Array(open.enumerated()), id: \.element.id) { index, proposal in
                    PushLink(.proposal(ProposalRef(proposal)), chevron: false) {
                        HStack {
                            ProposalRow(proposal: proposal)
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, Theme.Spacing.l)
                        .padding(.vertical, Theme.Spacing.s)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < open.count - 1 { Divider().padding(.leading, 84) }
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }

    private func grid(_ members: [LibraryBuckets.Item]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 3)], spacing: 3) {
            ForEach(members.prefix(shown)) { item in
                let id = item.id
                // A real button: VoiceOver, Switch Control and the hit-area audit see it as one.
                Button {
                    guard selecting else {
                        viewing = PhotoViewer.Start(id: id, ids: members.prefix(shown).map(\.id))
                        return
                    }
                    if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
                } label: {
                    AssetThumbnail(id: id, side: 110)
                        .aspectRatio(1, contentMode: .fill)
                        .matchedTransitionSource(id: id, in: zoom)
                        .overlay(alignment: .bottomTrailing) {
                            if selecting {
                                Image(systemName: selection.contains(id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(.white, selection.contains(id) ? Theme.accent : Color.black.opacity(0.3))
                                    .padding(6)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(item.date?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "Foto")))
                .accessibilityAddTraits(selecting && selection.contains(id) ? .isSelected : [])
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }

    /// Area chips; at the largest text sizes a menu, so every area stays reachable.
    @ViewBuilder
    private var bucketPicker: some View {
        if typeSize.isAccessibilitySize {
            // A menu with its own label: the system picker button cuts long names at this size.
            Menu {
                Picker("Anzeigen", selection: Binding(get: { bucket }, set: { select($0) })) {
                    ForEach(Self.buckets, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                MenuChoiceLabel(text: Text(bucket.label))
            }
            .accessibilityLabel(Text("Anzeigen"))
            .accessibilityValue(Text(bucket.label))
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.s) {
                    ForEach(Self.buckets, id: \.self) { b in
                        Button { select(b) } label: {
                            Text(b.label)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(b == bucket ? Theme.accent : Theme.card, in: Capsule())
                                .foregroundStyle(b == bucket ? Theme.onAccent : Color.primary)
                                // The capsule stays as it is; the tap area is 44 pt (design review W9).
                                .minimumHitTarget()
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(b == bucket ? .isSelected : [])
                    }
                }
            }
        }
    }

    /// The actions for the selected photos, in the system bottom bar: add to an album on the
    /// left, how many are selected in the middle, ignore on the right, like the selection in
    /// Photos. Each button keeps its name for VoiceOver and the large content viewer.
    @ToolbarContentBuilder
    private var selectionActions: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Button {
                addingToAlbum = Array(selection)
            } label: {
                Label("Zu Album hinzufügen", systemImage: "rectangle.stack.badge.plus")
            }
            .disabled(selection.isEmpty)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            // The bar keeps its height, so the count stays on one line and stops growing at the
            // first accessibility size; the large content viewer shows it in full.
            Text("\(selection.count.formatted()) ausgewählt")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .accessibilityShowsLargeContentViewer()
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            // Not red: nothing is deleted, and it can be taken back. In "Ignoriert" the way back
            // instead of ignoring again (design review D4).
            Button {
                if bucket == .ignored { model.unignore(Array(selection)) } else { model.ignore(Array(selection)) }
                withAnimation {
                    selection = []
                    selecting = false
                }
            } label: {
                if bucket == .ignored {
                    Label("Nicht mehr ignorieren", systemImage: "eye")
                } else {
                    Label("Ignorieren", systemImage: "eye.slash")
                }
            }
            .disabled(selection.isEmpty)
            .accessibilityIdentifier(bucket == .ignored ? "selection.unignore" : "selection.ignore")
        }
    }

    private func select(_ b: InboxBucket) {
        bucket = b
        selection = []
        shown = Self.page
        if b == .suggestions { selecting = false }
    }

    private var emptyTitle: LocalizedStringKey {
        bucket == .unorganized ? "Alles sortiert" : "Keine Fotos"
    }

    private var emptyDescription: LocalizedStringKey {
        switch bucket {
        case .unorganized:
            // "Nur 2026": the list holds what the ring counts, the photos of that year.
            if case .year(let year) = model.analysisScope {
                return "Alle gezählten Fotos aus \(String(year)) liegen in passenden Alben."
            }
            return "Alle gezählten Fotos liegen in passenden Alben."
        case .ignored: return "Fotos, die du ignorierst, tauchen hier auf und werden nicht mehr vorgeschlagen."
        default: return "In diesem Bereich gibt es gerade nichts."
        }
    }
}

/// Right after "Ignorieren": "12 Fotos ignoriert" with "Widerrufen" (design review D4), like
/// the undo note Mail shows after moving a message. It goes away by itself after a few
/// seconds (later with VoiceOver), and the photos can still be brought back from "Ignoriert".
struct IgnoreUndoBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let undo = model.lastIgnored {
            HStack(spacing: Theme.Spacing.m) {
                Label {
                    Text("\(undo.assets.count) \(undo.assets.count.formatted()) Fotos ignoriert")
                } icon: {
                    Image(systemName: "eye.slash")
                }
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("Widerrufen") { model.unignore(undo.assets) }
                    .font(.subheadline.weight(.semibold))
                    .minimumHitTarget()
                    .accessibilityIdentifier("ignore.undo")
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.xs)
            .floatingPanel(cornerRadius: 22)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.bottom, Theme.Spacing.s)
            .accessibilityElement(children: .contain)
            .motionAwareTransition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// One photo, large, with what Albumist knows about it and why it is (not) sorted.
struct AssetDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var facts: AssetFacts
    var addToAlbum: () -> Void

    var body: some View {
        NavigationRoot {
            List {
                // The photo itself is behind this sheet, in the viewer (design review W12).
                Section {
                    if let date = facts.asset.creationDate {
                        LabeledContent("Aufgenommen", value: date.formatted(date: .long, time: .shortened))
                    }
                    if let place = placeText {
                        LabeledContent("Ort", value: place)
                    }
                    if let state = model.states[facts.id] {
                        LabeledContent("Status") { Text(statusLabel(state)) }
                    }
                }
                Section {
                    if albums.isEmpty {
                        Text("Noch in keinem Album").foregroundStyle(.secondary)
                    }
                    ForEach(albums, id: \.self) { title in
                        Label(title, systemImage: "rectangle.stack")
                    }
                } header: {
                    Text("Alben")
                }
                let suggestions = model.proposals(containing: facts.id)
                if !suggestions.isEmpty {
                    Section {
                        ForEach(suggestions.prefix(6)) { proposal in
                            PushLink(.proposal(ProposalRef(proposal))) {
                                ProposalRow(proposal: proposal)
                            }
                        }
                    } header: {
                        Text("Vorschläge für dieses Foto")
                    } footer: {
                        Text("Tippe auf einen Vorschlag, um ihn anzusehen und auszuwählen.")
                    }
                } else if let reason = reasonText {
                    Section("Warum unsortiert?") {
                        Text(reason).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button {
                        dismiss()
                        addToAlbum()
                    } label: {
                        Label("Zu Album hinzufügen", systemImage: "rectangle.stack.badge.plus")
                    }
                    // No destructive role: ignoring deletes nothing and can be taken back
                    // (design review D4); an ignored photo offers the way back here too.
                    if isIgnored {
                        Button {
                            model.unignore([facts.id])
                            dismiss()
                        } label: {
                            Label("Nicht mehr ignorieren", systemImage: "eye")
                        }
                        .accessibilityIdentifier("detail.unignore")
                    } else {
                        Button {
                            model.ignore([facts.id])
                            dismiss()
                        } label: {
                            Label("Ignorieren", systemImage: "eye.slash")
                        }
                        .accessibilityIdentifier("detail.ignore")
                    }
                } footer: {
                    if isIgnored {
                        Text("Albumist zählt das Foto dann wieder mit und kann es wieder vorschlagen.")
                    } else {
                        Text("Ignorierte Fotos schlägt Albumist nicht mehr vor. Am Foto selbst ändert sich nichts, und du kannst es jederzeit rückgängig machen.")
                    }
                }
            }
            .accessibilityIdentifier("detail.list")
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // An xmark like the viewer's own close button: "Fertig" was clipped at the
                // largest text size (UI run 43773339053).
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Label("Schließen", systemImage: "xmark") }
                        .accessibilityIdentifier("detail.close")
                }
            }
        }
    }

    /// A photo the ring does not count (no main area applies, or outside the chosen year) is
    /// not "Sortiert": it is not in that list either (one meaning of sorted, Fuchs 18.11.).
    private func statusLabel(_ state: AssetOrganizationState) -> LocalizedStringKey {
        let inScope = model.analysisScope.includes(facts, calendar: .sortlyDefault)
        switch model.resolver.ringPart(state, inScope: inScope) {
        case .outsideMainAreas, .outsideScope: return "Nicht mitgezählt"
        case .unsorted:
            // Not „Unsortiert“ right above the albums the photo is in: the areas it lacks an
            // album of („Noch in keinem Album für „Reisen““), the rule of the status itself.
            let missing = UnsortedReason.missingAreas(state, primaryAreas: model.resolver.primaryAreas)
            guard !missing.isEmpty else { return model.resolver.overall(state).label }
            let open = Locale.current.quotationBeginDelimiter ?? "\"", close = Locale.current.quotationEndDelimiter ?? "\""
            let names = missing.map { open + String(localized: $0.titleResource) + close }
            return "Noch in keinem Album für \(names.formatted(.list(type: .or)))"
        default: return model.resolver.overall(state).label
        }
    }

    private var isIgnored: Bool {
        model.states[facts.id].map { model.resolver.overall($0) == .ignored } ?? false
    }

    private var placeText: String? {
        guard let place = facts.place else { return nil }
        let parts = [place.locality, place.country].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private var albums: [String] {
        facts.albumIDs.compactMap { model.inventory[$0]?.title }.sorted()
    }

    private var reasonText: LocalizedStringKey? {
        guard let state = model.states[facts.id] else { return "Die Analyse ist für dieses Foto noch nicht fertig." }
        switch model.resolver.overall(state) {
        case .fullyOrganized: return nil
        case .ignored: return "Du hast dieses Foto ignoriert."
        case .excluded: return "Dieses Foto ist von der Analyse ausgeschlossen, zum Beispiel weil es ausgeblendet ist."
        default:
            // Outside the chosen year the ring does not count the photo ("Nicht mitgezählt" above).
            // Only for photos that are not sorted: a sorted photo needs no "Warum unsortiert?" (review 18.11.).
            if case .year(let year) = model.analysisScope,
               model.resolver.ringPart(state, inScope: model.analysisScope.includes(facts, calendar: .sortlyDefault)) == .outsideScope {
                return "Albumist zählt gerade nur Fotos aus \(String(year))."
            }
            let statuses = Set(state.areas.values)
            if statuses.contains(.proposed) || statuses.contains(.pendingConfirmation) {
                return "Es gibt schon einen Vorschlag dafür. Du findest ihn in der Übersicht."
            }
            if facts.place == nil && facts.asset.kind != .video && !facts.asset.isScreenshotLike {
                return "Das Foto hat keinen Ort und passt zu keinem Thema. Du kannst es selbst in ein Album legen."
            }
            return "Es passt zu keinem deiner eingeschalteten Bereiche. Du kannst es selbst in ein Album legen."
        }
    }
}

/// Pick an existing album or name a new one; the change then goes through the normal review.
struct AddToAlbumSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var assets: [AssetID]
    var onDone: () -> Void
    @State private var newTitle = ""
    @State private var query = ""
    /// The sheet's stack; the preview of the plan is pushed onto it as a value (`AppScreen`).
    /// Not `navigationDestination(isPresented:)`: with it, the preview was presented again and
    /// again, 11,062 times in one 36 s stall of the main thread (UI run 44055738268, device
    /// test 05: "plan review body" counter, the stacks in SwiftUI's navigation updates).
    @State private var navigator = Navigator()
    @FocusState private var naming: Bool

    var body: some View {
        let _ = MainThreadWatch.shared.count("add to album body")
        NavigationRoot(navigator) {
            List {
                Section {
                    HStack {
                        TextField("Name des neuen Albums", text: $newTitle)
                            .focused($naming)
                            .submitLabel(.done)
                            .onSubmit { Task { await prepare(target: nil) } }
                        Button("Anlegen") { Task { await prepare(target: nil) } }
                            .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Neues Album")
                }
                Section {
                    // The system's empty search state (design review N12).
                    if albums.isEmpty && !query.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else if albums.isEmpty {
                        Text("Noch keine Alben").foregroundStyle(.secondary)
                    }
                    ForEach(albums) { album in
                        Button {
                            Task { await prepare(target: album.id) }
                        } label: {
                            HStack {
                                Label(album.title, systemImage: "rectangle.stack")
                                Spacer()
                                Text(album.assetIDs.count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Deine Alben")
                }
            }
            .searchable(text: $query, prompt: Text("Album suchen"))
            .navigationTitle(Text("\(assets.count) \(assets.count.formatted()) Fotos hinzufügen"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // A round close button: the wider "Abbrechen" pushed the title off centre.
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Label("Schließen", systemImage: "xmark") }
                }
            }
            .onChange(of: model.execution.finished) { _, finished in
                if finished != nil { onDone() }
            }
        }
    }

    private var albums: [CollectionSnapshot] {
        let all = model.inventory.albums.filter(\.isEditableAlbum)
        let filtered = query.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(query) }
        return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func prepare(target: CollectionID?) async {
        // The keyboard goes first, on this screen, and the preview slides in once it is down.
        // In UI run 44038288087 (device test 05, two of three new albums) the main thread hung
        // for 52 and 68 s right after "Anlegen": each stack that reached deep enough showed the
        // keyboard's hiding laying out the sheet while the preview was pushed into it, and
        // SwiftUI drawing that preview.
        let hadKeyboard = naming
        naming = false
        let title = target == nil ? newTitle.trimmingCharacters(in: .whitespaces) : nil
        guard let built = await model.manualPlan(assets: assets, target: target, newTitle: title) else { return }
        // The keyboard takes about a quarter of a second to go down.
        if hadKeyboard { try? await Task.sleep(for: .milliseconds(400)) }
        navigator.path = [.prebuiltPlan(PlanToken(built))]
    }
}
