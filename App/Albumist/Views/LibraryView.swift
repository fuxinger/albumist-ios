import SwiftUI
import AlbumistCore
import AlbumistEngine

/// The tab "Unsortiert" (design W1, tabs 6B): what is not sorted yet, unsure or ignored
/// (`LibraryBuckets.unsortedTabFilters`), with ignore. Suggestions have a tab of their own.
///
/// The photos by day, as Photos shows its days (design wave 3, DS-21, `InboxDays`): the newest
/// day first, as an inbox of what is left to sort, each day's photos in the order they were
/// taken, the photos without a date last; in the photo grid a suggestion's photos have too
/// (`PhotoGrid`, DS-06b: drag to select, pinch to zoom).
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
    /// "Einstellungen öffnen" in an empty list when no main area counts (as on the overview).
    @State private var showSettings = false
    /// Photos asked for so far: the grid shows this many from the top, more on request, so large
    /// libraries stay smooth and every photo can still be reached; a day larger than that is cut
    /// where the page ends (`InboxDays.shown`).
    @State private var shown = Self.page
    /// The shown area's photos by day, made off the main thread (`AppModel.inboxDays`), and the
    /// area they are of: while an area's days are made anew its days before stay.
    @State private var days = InboxDays()
    @State private var daysBucket: InboxBucket?
    /// Today's number on the iPhone's clock, for "Heute" and "Gestern", and the clock's zone, on
    /// which photos without a zone of their own are read: read anew at midnight and at a new time
    /// zone (iOS says a significant time changed) and when the app is back on screen, so a tab
    /// left open overnight or taken to another zone makes its days anew (review L11, W10).
    @State private var today = Self.today()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var typeSize

    private static let page = 3_000

    var body: some View {
        let _ = MainThreadWatch.shared.count("library body")
        // Made off the main thread (`AppModel.libraryBuckets`); `nil` only before the first pass.
        let members = model.libraryBuckets?[bucket]
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                bucketPicker
                    .padding(.horizontal, Theme.Spacing.l)
                if let members {
                    content(members)
                } else {
                    preparing
                }
            }
            .padding(.bottom, Theme.Spacing.xl)
        }
        // The grid scrolls the page while a finger selects at an edge, and keeps its place
        // when it zooms.
        .photoGridScrolling()
        .background(Theme.background)
        .task(id: DaysKey(bucket: bucket, members: members, words: model.proposalWords, today: today)) {
            await makeDays(of: members, in: bucket)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            today = Self.today()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { today = Self.today() }
        }
        .onAppear { model.showLibraryBuckets() }
        .onDisappear { model.hideLibraryBuckets() }
        .navigationTitle("Unsortiert")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(selecting ? "Fertig" : "Auswählen") {
                    withAnimation {
                        selecting.toggle()
                        selection = []
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
        .sheet(isPresented: $showSettings) {
            NavigationRoot { SettingsView() }
                .sheetSize(.page)
        }
        .sheet(isPresented: Binding(get: { addingToAlbum != nil }, set: { if !$0 { addingToAlbum = nil } })) {
            AddToAlbumSheet(assets: addingToAlbum ?? []) {
                // Animated like the other ways out, so the tab bar does not snap back.
                withAnimation {
                    selection = []
                    selecting = false
                }
            }
            .sheetSize(.page)
        }
        .refreshable { await model.refreshDerived() }
    }

    /// One area's count and its photos by day.
    @ViewBuilder
    private func content(_ members: [LibraryBuckets.Item]) -> some View {
        // Numbers as plural strings (design review W5: "1 Fotos und Videos").
        Text("\(members.count) \(members.count.formatted()) Fotos und Videos")
            .font(.footnote).foregroundStyle(.noteText).monospacedDigit()
            .padding(.horizontal, Theme.Spacing.l)

        if members.isEmpty {
            Group {
                if SortedCountCard.EmptyList.make(bucket, settings: model.settings) == .noMainAreaChosen {
                    // Nothing counts as sorted: the way to change that, as on the overview's card.
                    ContentUnavailableView {
                        Label(emptyTitle, systemImage: "circle.dashed")
                    } description: {
                        Text(emptyDescription)
                    } actions: {
                        Button("Einstellungen öffnen") { showSettings = true }
                            .accessibilityIdentifier("library.openSettings")
                    }
                } else {
                    ContentUnavailableView(emptyTitle, systemImage: "photo.on.rectangle",
                                           description: Text(emptyDescription))
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
        } else if daysBucket == bucket, !days.sections.isEmpty {
            // A page of photos from the top: the last day is cut where the page ends (its header
            // still counts the whole day), so one page never holds more, whatever a day holds.
            let page = days.shown(forPhotos: shown)
            grid(days.sections.prefix(page.days), limit: page.photos)
            if page.photos < days.photoCount {
                moreComing(after: page.photos)
            }
        } else {
            // Another area's days, or the days of the area while it was empty, are being made
            // anew (a moment in a very large library).
            preparing
        }
    }

    /// The days shown, their photos below position `limit` (the last day may be cut there).
    private func grid(_ days: ArraySlice<PhotoGridSection>, limit: Int) -> some View {
        PhotoGrid(sections: days, limit: limit, place: .unsorted, selecting: selecting, selection: $selection,
                  pinsHeaders: true, zoom: zoom, identifier: "library.photo") { id in
            open(id)
        } perform: { item, id in
            perform(item, on: id)
        }
    }

    /// The first pass over all photos, and an area whose days are being made: a calm line, no
    /// spinner (DS-18). Not "Alles sortiert" or "0 Fotos": that would not be true yet.
    private var preparing: some View {
        Text("Fotos werden zusammengestellt …")
            .font(.footnote)
            .foregroundStyle(.noteText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.l)
            .accessibilityIdentifier("library.preparing")
    }

    /// Below the photos shown so far (`photos`): the next page comes by itself when this line
    /// comes into view (design review N10: a button every 3,000 photos), the rest of a cut day
    /// first.
    private func moreComing(after photos: Int) -> some View {
        Text("Weitere Fotos werden geladen")
            .font(.footnote)
            .foregroundStyle(.noteText)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.m)
            .onScrollVisibilityChange(threshold: 0.1) { visible in
                if visible { shown = photos + Self.page }
            }
            .accessibilityIdentifier("library.loadingMore")
    }

    /// The photo large, every photo of the area in the grid's order to swipe through, not only
    /// the pages shown so far: the viewer builds its pages in a window (`PageWindow`). With the
    /// grid's first page it said "11 von 3.000" in a larger library and stopped there (iPhone,
    /// Build 41, 26.11.2026).
    private func open(_ id: AssetID) {
        viewing = PhotoViewer.Start(id: id, ids: PhotoGridSection.ids(of: days.sections))
    }

    /// An item of the photo's long press, the way "Unsortiert" goes it: "Ansehen" as a tap,
    /// "Zu Album hinzufügen …" the sheet the selection opens (then the preview).
    private func perform(_ action: PhotoMenu.Item, on id: AssetID) {
        switch action {
        case .view: open(id)
        case .addToAlbum: addingToAlbum = [id]
        // Ignoring is the model's, the same everywhere (`PhotoMenuItems`); a suggestion's own.
        case .ignore, .stopIgnoring, .removeFromSuggestion: break
        }
    }

    // MARK: The days

    /// What the shown area's days are made of: the area, its photos as the model handed them
    /// over (the same array, not equal contents: comparing 100,000 photos at every draw would
    /// cost what grouping them off the main thread saves), the app's language, and which day is
    /// "Heute" on which clock.
    private struct DaysKey: Equatable {
        var bucket: InboxBucket
        var members: [LibraryBuckets.Item]?
        var words: ProposalWords
        var today: Today

        static func == (a: DaysKey, b: DaysKey) -> Bool {
            guard a.bucket == b.bucket, a.words == b.words, a.today == b.today else { return false }
            switch (a.members, b.members) {
            case (nil, nil): return true
            case let (x?, y?): return LibraryView.same(x, y)
            default: return false
            }
        }
    }

    /// The same array (its storage), whatever its contents.
    nonisolated private static func same<T>(_ a: [T], _ b: [T]) -> Bool {
        guard a.count == b.count else { return false }
        if a.isEmpty { return true }
        return a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in pa.baseAddress == pb.baseAddress } }
    }

    /// Which day is today on the iPhone's clock (`LocalTime.day`), and the clock's zone by its
    /// identifier: the days say "Heute" and "Gestern", and a photo without a zone of its own is on
    /// the day the iPhone's clock gives it (review W10: a new zone can keep the day's number).
    private struct Today: Equatable {
        var day: Int
        var zone: String
    }

    private static func today() -> Today {
        let zone = TimeZone.current
        return Today(day: LocalTime.day(LocalTime.wallClock(Date(), in: zone)), zone: zone.identifier)
    }

    /// Groups the area's photos by day off the main thread. Given up when a newer area comes
    /// (the task's id changes) or the tab goes; an empty area has no days to make.
    private func makeDays(of members: [LibraryBuckets.Item]?, in bucket: InboxBucket) async {
        guard let members else { return }
        let made: InboxDays?
        if members.isEmpty {
            made = InboxDays()
        } else {
            made = await model.inboxDays(members)
        }
        guard let made, !Task.isCancelled else { return }
        days = made
        daysBucket = bucket
    }

    /// The tab's filters as chips; at the largest text sizes a menu, so every filter stays
    /// reachable. UI tests find them by identifier: `library.filter` for the row or the menu,
    /// `library.filter.<area>` for each chip (e.g. `library.filter.ignored`).
    @ViewBuilder
    private var bucketPicker: some View {
        if typeSize.isAccessibilitySize {
            // A menu with its own label: the system picker button cuts long names at this size.
            Menu {
                Picker("Anzeigen", selection: Binding(get: { bucket }, set: { select($0) })) {
                    ForEach(LibraryBuckets.unsortedTabFilters, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                MenuChoiceLabel(text: Text(bucket.label))
            }
            .accessibilityLabel(Text("Anzeigen"))
            .accessibilityValue(Text(bucket.label))
            .accessibilityIdentifier("library.filter")
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.s) {
                    ForEach(LibraryBuckets.unsortedTabFilters, id: \.self) { b in
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
                        .accessibilityIdentifier("library.filter.\(b.rawValue)")
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("library.filter")
        }
    }
}

// MARK: Selection and an empty area

extension LibraryView {
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
    }

    /// With no main area counted, "Unsortiert" says what the start page says, not "Alles
    /// sortiert" (`SortedCountCard.EmptyList`, finding N-01).
    private var emptyTitle: LocalizedStringKey {
        switch SortedCountCard.EmptyList.make(bucket, settings: model.settings) {
        case .noMainAreaChosen: "Kein Bereich zählt als sortiert"
        case .allSorted: "Alles sortiert"
        case .noPhotos: "Keine Fotos"
        }
    }

    private var emptyDescription: LocalizedStringKey {
        switch SortedCountCard.EmptyList.make(bucket, settings: model.settings) {
        case .noMainAreaChosen:
            return "Wähle in den Einstellungen unter „Zählt als sortiert“, welche Bereiche zählen."
        case .allSorted:
            // "Nur 2026": the list holds what the ring counts, the photos of that year.
            if case .year(let year) = model.analysisScope {
                return "Alle gezählten Fotos aus \(String(year)) liegen in passenden Alben."
            }
            return "Alle gezählten Fotos liegen in passenden Alben."
        case .noPhotos:
            if bucket == .ignored { return "Fotos, die du ignorierst, tauchen hier auf und werden nicht mehr vorgeschlagen." }
            return "In diesem Bereich gibt es gerade nichts."
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
                // The 44 pt tap area on the label, where the button takes the tap.
                Button { model.unignore(undo.assets) } label: {
                    Text("Widerrufen").minimumHitTarget()
                }
                .font(.subheadline.weight(.semibold))
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
                    // On the photo's clock, as the title above says it (design run of 25.11.).
                    if let date = facts.asset.creationDate {
                        let taken = PhotoTitle.takenAt(date, zone: facts.timeZone, currentZone: .current, words: model.proposalWords,
                                                       clock: AppModel.deviceClock())
                        LabeledContent("Aufgenommen", value: taken)
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
                        // Two lines (decision 8A); the way back is "Nicht mehr ignorieren".
                        Text("Ignorierte Fotos schlägt Albumist nicht mehr vor. Am Foto selbst ändert sich nichts.")
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
        let inScope = model.analysisScope.includes(facts, calendar: .albumistDefault)
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
        // No main area counts: the ring counts no photo ("Nicht mitgezählt" above), as the
        // overview says (finding N-01). Ignored and excluded photos say so below.
        if SortedCountCard.photoInfoNamesNoMainArea(state, settings: model.settings) {
            return "Wähle in den Einstellungen unter „Zählt als sortiert“, welche Bereiche zählen."
        }
        switch model.resolver.overall(state) {
        case .fullyOrganized: return nil
        case .ignored: return "Du hast dieses Foto ignoriert."
        case .excluded: return "Dieses Foto ist von der Analyse ausgeschlossen, zum Beispiel weil es ausgeblendet ist."
        default:
            // Outside the chosen year the ring does not count the photo ("Nicht mitgezählt" above).
            // Only for photos that are not sorted: a sorted photo needs no "Warum unsortiert?" (review 18.11.).
            if case .year(let year) = model.analysisScope,
               model.resolver.ringPart(state, inScope: model.analysisScope.includes(facts, calendar: .albumistDefault)) == .outsideScope {
                return "Albumist zählt gerade nur Fotos aus \(String(year))."
            }
            let statuses = Set(state.areas.values)
            if statuses.contains(.proposed) || statuses.contains(.pendingConfirmation) {
                return "Es gibt schon einen Vorschlag dafür. Du findest ihn unter „Vorschläge“."
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
                        // "…": the preview opens first (design W1, Punkt 2).
                        Button("Anlegen …") { Task { await prepare(target: nil) } }
                            .disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityIdentifier("addToAlbum.create")
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
