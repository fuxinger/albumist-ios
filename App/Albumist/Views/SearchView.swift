import SwiftUI
import AlbumistCore
import AlbumistEngine

/// Natural search over the analysed library (prompt §14), e.g. "Hunde Italien 2023".
/// Every search runs on a prepared index in a few milliseconds, so results follow the
/// typing; the chips show how the query was understood, with a photo count per term.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    /// What is typed, held by the tabs (design wave 3, DS-12a), wherever `MainTabs.searchField`
    /// puts the field: on the tab view as Apple's search tab, or on this page as until wave 3.
    let input: SearchInput
    @State private var result = SearchResult()
    /// The text `result` belongs to; the field runs ahead while a search is pending.
    @State private var resultQuery = ""
    @State private var searching = false
    /// Completions for the word being typed, from the user's own library.
    @State private var suggestions: [SearchSuggestion] = []
    /// Starting points for the empty field, from the user's own library.
    @State private var featured: [SearchSuggestion] = []
    /// The same with a photo each (design wave 3, DS-13): shown as tiles once there are any.
    @State private var starts: [SearchStartingPoint] = []
    /// A tap opens the photo large, its details behind "i" (design review W12).
    @State private var viewing: PhotoViewer.Start?
    /// The tapped thumbnail (a photo can be in the best hits and in the grid).
    @State private var zoomSource = ""
    @State private var addingToAlbum: [AssetID]?
    /// Thumbnails shown so far; the count and "Als Album anlegen" always cover every hit.
    @State private var shown = Self.page
    private static let page = 2_000
    /// The side a photo's thumbnail is asked for, and its long press lifts that image.
    private static let photoSide: CGFloat = 110
    @Namespace private var zoom
    /// The column of a suggestion's symbol grows with the text size: a fixed 24 pt let the
    /// symbol run over the word at the largest size (review P3-12 / G3-07).
    @ScaledMetric(relativeTo: .body) private var symbolWidth: CGFloat = 24

    /// Shown only before the library is analysed (afterwards the library's own starting points).
    /// Translated (design review W6: English devices saw "Strand 2024"); the search understands
    /// both languages, see `SearchExampleTests`.
    private let examples: [LocalizedStringResource] = ["Strand 2024", "Italien", "Rechnungen", "Videos", "Unsortiert", "Screenshots Bestellung"]

    /// The field's text: the starting points and the completions set it, the search follows it.
    private var query: String {
        get { input.text }
        nonmutating set { input.text = newValue }
    }

    private var isEmptyQuery: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The field's prompt, wherever the field sits: an example the search understands, a whole
    /// sentence when Apple Intelligence can turn it into terms (`SmartAssistant`).
    static var prompt: Text {
        SmartAssistant.isAvailable ? Text("z. B. Grillen bei Oma letzten Sommer") : Text("z. B. Hunde Italien 2023")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                if isEmptyQuery {
                    startingPoints
                } else {
                    if !suggestions.isEmpty { suggestionList }
                    if let rewrite = model.lastSearchRewrite, !searching {
                        Label("Verstanden als: \(rewrite)", systemImage: "apple.intelligence")
                            .font(.footnote).foregroundStyle(.noteText)
                    }
                    if !result.tokens.isEmpty {
                        FlowLayout(spacing: Theme.Spacing.xs) {
                            ForEach(Array(result.tokens.enumerated()), id: \.offset) { _, token in
                                SearchTokenChip(token: token, dropped: result.dropped.contains(token))
                            }
                        }
                    }
                    if result.isRelaxed { relaxedNote }
                    if result.ids.isEmpty {
                        // The previous answer stays while the next one is computed (no flicker).
                        if resultQuery.isEmpty {
                            // The first answer is worked out: calm tiles where the hits will be
                            // (design wave 3, DS-18: no spinner).
                            waitingTiles(count: 6)
                                .accessibilityLabel(Text("Suche läuft"))
                        } else {
                            emptyState
                        }
                    } else {
                        hits
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.l)
        }
        .background(Theme.background)
        .navigationTitle("Suchen")
        .fullScreenCover(item: $viewing) { start in
            PhotoViewer(ids: start.ids, current: start.id, showsInfo: true)
                .navigationTransition(.zoom(sourceID: zoomSource, in: zoom))
        }
        .sheet(isPresented: Binding(get: { addingToAlbum != nil }, set: { if !$0 { addingToAlbum = nil } })) {
            AddToAlbumSheet(assets: addingToAlbum ?? []) {}
                .sheetSize(.page)
        }
        // "Widerrufen" after ignoring a photo from its detail (design review D4).
        .safeAreaInset(edge: .bottom) { IgnoreUndoBar() }
        .animation(.snappy, value: model.lastIgnored)
        // The field here only when the switch keeps it on the page (`MainTabs.searchField`);
        // otherwise it sits on the tab view and this page reads what is typed there.
        .searchField(input, on: .page)
        // Starting points follow every change of the facts (a finished analysis brings places and
        // topics, the pictures of photos it has looked at since), also one of a photo's rank
        // alone: the text step finds a sensitive document without changing a count, and its
        // tile does not keep showing it (review G2). Both lists are shown together; a task
        // cancelled meanwhile starts no more work and keeps nothing.
        .task(id: model.factsVersion) {
            let words = await model.featuredSearches()
            guard !Task.isCancelled else { return }
            let made = await model.searchStartingPoints()
            guard !Task.isCancelled else { return }
            featured = words
            starts = made
        }
        .task(id: query) {
            let text = query
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                result = SearchResult(); resultQuery = ""; suggestions = []; searching = false
                return
            }
            searching = true
            // Completions right away; the search itself waits until typing pauses.
            let completions = await model.searchSuggestions(for: text)
            suggestions = completions
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await model.search(text)
            guard !Task.isCancelled else { return }
            // A word the completions continue is still being typed, never "nicht erkannt" (P3-13).
            result = found.beside(completions, for: text)
            resultQuery = text
            shown = Self.page
            searching = false
        }
    }

    // MARK: Parts

    /// What the empty field offers: the library's starting points as photo tiles (DS-13), a tap
    /// searches a tile's words as its chip did; papers ("Rechnungen") stay words beside them, as
    /// their pictures are personal. Before the analysis has found anything with a photo, the
    /// words alone, as before: the library's chips, or the fixed examples.
    private var startingPoints: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("Suche nach Orten, Jahren, Themen oder Text auf Screenshots.")
                .foregroundStyle(.secondary)
            if !starts.isEmpty {
                SearchStartingPointGrid(points: starts) { suggestion in query = suggestion.completion }
            }
            let words = starts.isEmpty ? featured : featured.filter { $0.kind == .document }
            if starts.isEmpty && featured.isEmpty {
                FlowLayout(spacing: Theme.Spacing.s) {
                    ForEach(examples.map { String(localized: $0) }, id: \.self) { example in
                        Button(example) { query = example }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .accessibilityIdentifier("search.example")
                    }
                }
            } else if !words.isEmpty {
                FlowLayout(spacing: Theme.Spacing.s) {
                    ForEach(words) { suggestion in
                        Button { query = suggestion.completion } label: {
                            Label(suggestion.label, systemImage: Self.symbol(suggestion.kind))
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .accessibilityValue(Text("\(suggestion.count) \(suggestion.count.formatted()) Fotos"))
                        .accessibilityIdentifier("search.example")
                    }
                }
            }
        }
    }

    /// Like the completions in Photos: what the library holds for the word being typed.
    private var suggestionList: some View {
        VStack(spacing: 0) {
            ForEach(suggestions.prefix(4)) { suggestion in
                Button {
                    // The space ends the word: the list closes and the results stay in view.
                    query = suggestion.completion + " "
                } label: {
                    HStack(spacing: Theme.Spacing.s) {
                        Image(systemName: Self.symbol(suggestion.kind))
                            .foregroundStyle(.secondary)
                            .frame(width: symbolWidth)
                        Text(verbatim: suggestion.label)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(suggestion.count.formatted())
                            .font(.footnote).foregroundStyle(.noteText).monospacedDigit()
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: suggestion.label))
                .accessibilityValue(Text("\(suggestion.count) \(suggestion.count.formatted()) Fotos"))
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("search.suggestion")
            }
        }
    }

    private func thumbnail(_ id: AssetID, source: String) -> some View {
        let hit = model.factsByID[id]
        let key = source + ":" + id.rawValue
        return Button {
            open(id, from: key)
        } label: {
            AssetThumbnail(id: id, side: Self.photoSide)
                .aspectRatio(1, contentMode: .fill)
                .matchedTransitionSource(id: key, in: zoom)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(hit == nil)
        .accessibilityLabel(Text(hit?.asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "Foto")))
        .accessibilityIdentifier("search.result")
        // The long press (DS-06a): the photo larger, with what a hit offers.
        .photoMenu(id, place: .search, side: Self.photoSide, available: hit != nil) { action in
            perform(action, on: id, from: key)
        }
    }

    /// The photo large, zooming out of the thumbnail `key` (a photo can be in the best hits and
    /// in the grid).
    private func open(_ id: AssetID, from key: String) {
        zoomSource = key
        // The best hits sit above the grid and may lie beyond the pages shown: the
        // viewer always contains the photo that was tapped.
        var ids = Array(result.ids.prefix(shown))
        if !ids.contains(id) { ids.insert(id, at: 0) }
        viewing = PhotoViewer.Start(id: id, ids: ids)
    }

    /// An item of a hit's long press, the search's way: "Ansehen" as a tap, "Zu Album
    /// hinzufügen …" the sheet "Als Album anlegen" opens (then the preview).
    private func perform(_ action: PhotoMenu.Item, on id: AssetID, from key: String) {
        switch action {
        case .view: open(id, from: key)
        case .addToAlbum: addingToAlbum = [id]
        // Ignoring is the model's, the same everywhere (`PhotoMenuItems`); a suggestion's own.
        case .ignore, .stopIgnoring, .removeFromSuggestion: break
        }
    }

    static func symbol(_ kind: SearchToken.Kind) -> String {
        switch kind {
        case .country: "globe.europe.africa"
        case .place: "mappin.and.ellipse"
        case .year, .month, .date: "calendar"
        case .mediaType: "photo.on.rectangle"
        case .category: "tag"
        case .document: "doc.text"
        case .merchant: "bag"
        case .field: "number"
        case .group: "person.2"
        case .album: "rectangle.stack"
        case .location: "location"
        case .status: "tray.full"
        case .text: "text.magnifyingglass"
        case .trip: "airplane"
        case .favorite: "heart"
        case .ignored: "questionmark.circle"
        }
    }
}

/// The hits and what stands in their place: the note when terms were left out, the empty
/// states and the calm tiles while hits load (apart from the struct's body, SwiftLint's type
/// body length).
extension SearchView {
    /// Nothing matched every term: the search left the least important ones out and says so.
    private var relaxedNote: some View {
        Label {
            Text("Kein Foto passt zu allen Begriffen. Ohne \(result.dropped.map(\.label).formatted(.list(type: .and))) gesucht.")
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.footnote)
        .foregroundStyle(.noteText)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("search.relaxed")
    }

    /// Never an unexplained empty page: says whether nothing was understood or which term
    /// has no photos at all. Nothing while the completions above stand for the word being
    /// typed (`SearchResult.emptyState`, review P3-13).
    private var emptyState: some View {
        Group {
            switch result.emptyState {
            case .notRecognized:
                // Says what to try instead (design review N14).
                ContentUnavailableView("Suchbegriff nicht erkannt", systemImage: "questionmark.circle",
                                       description: Text("Versuch es mit einem Ort, einem Jahr, einem Thema oder Text auf einem Screenshot."))
            case .noPhotos(let missing):
                ContentUnavailableView("Keine Fotos", systemImage: "magnifyingglass",
                                       description: Text("Zu „\(missing.label)“ gibt es keine Fotos in deiner Mediathek."))
            case .noMatch:
                ContentUnavailableView.search(text: resultQuery)
            case nil:
                EmptyView()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("search.empty")
    }

    @ViewBuilder private var hits: some View {
        // The best hits first when the analysis is surer about some photos than others.
        if !result.top.isEmpty {
            Text("Beste Treffer").font(.headline)
            ScrollView(.horizontal) {
                HStack(spacing: 3) {
                    ForEach(result.top, id: \.self) { id in
                        thumbnail(id, source: "top")
                            .frame(width: 120, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        HStack {
            Text("\(result.ids.count) \(result.ids.count.formatted()) Treffer").font(.footnote).foregroundStyle(.noteText).monospacedDigit()
                .accessibilityIdentifier("search.count")
            Spacer()
            // The search becomes an album in Photos (through the normal preview).
            Button { addingToAlbum = result.ids } label: {
                Text("Als Album anlegen")
                    .font(.footnote.weight(.semibold))
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 3)], spacing: 3) {
            ForEach(result.ids.prefix(shown), id: \.self) { id in
                thumbnail(id, source: "grid")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        if result.ids.count > shown {
            // The next hits load by themselves at the end of the grid (design review N10), on
            // calm tiles where they will be (DS-18).
            waitingTiles(count: 3)
                .onScrollVisibilityChange(threshold: 0.1) { visible in
                    if visible { shown += Self.page }
                }
                .accessibilityLabel(Text("Weitere Treffer werden geladen"))
                .accessibilityIdentifier("search.loadingMore")
        }
    }

    /// Tiles on the thumbnails' calm ground (`ThumbnailGround`) where hits will be, while they
    /// are worked out: no spinner (design wave 3, DS-18). One element for VoiceOver, which the
    /// caller names.
    private func waitingTiles(count: Int) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 3)], spacing: 3) {
            ForEach(0..<count, id: \.self) { _ in
                ThumbnailGround()
                    .aspectRatio(1, contentMode: .fill)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .accessibilityElement(children: .ignore)
    }
}

/// What is typed in the search field and whether the field is active (design wave 3, DS-12a).
/// The tabs hold it (`MainTabs`), so the field can sit on the tab view as Apple's search tab and
/// the search outlives a look at another tab; the search page reads and sets the text. No other
/// field binds it: "Album suchen" and "Ort suchen" search a text of their own view, so typing
/// there never starts a search.
@MainActor @Observable
final class SearchInput {
    var text = ""
    var isPresented = false
    /// The field has the keyboard: with `.tabViewKeepingSearch` mirrored from the field's focus
    /// (`SearchFieldModifier`); set to false, the keyboard goes and the search stays.
    var isFocused = false

    /// A route (Siri, Shortcuts, Spotlight, a notification) leaves the search tab in code
    /// (`MainTabs`; review T2 of H14's round 2). With `.tabViewKeepingSearch` only the keyboard
    /// goes: the query, the hits and the scroll position stay, as after a look at another tab
    /// (ending the search would empty the field: Apple, dismissing a search clears its text).
    /// With `.tabViewOpeningKeyboard` and `.pageFocusingField` the search ends, so neither its
    /// field nor the keyboard stays up over "Vorschläge", and the field empties.
    func leftInCode() {
        if MainTabs.searchField == .tabViewKeepingSearch {
            isFocused = false
        } else {
            isPresented = false
        }
    }

    /// Where the field sits, and so how the search behaves: the place decides more than the look
    /// (review S1 of H14). `MainTabs.searchField` chooses one.
    enum Placement {
        /// On the tab view, Apple's search tab: choosing it shows the page with its starting
        /// points (DS-13) and the field; the keyboard comes when the field is tapped; the query,
        /// the hits and the scroll position stay while another tab is looked at.
        case tabViewKeepingSearch
        /// On the tab view, and choosing the tab activates the field: the keyboard comes every
        /// time, also over an earlier query; closing the field goes back to the tab before and
        /// empties it.
        case tabViewOpeningKeyboard
        /// On the search page's own stack, as until wave 3: the field is focused as the page
        /// opens with nothing typed; the search stays while another tab is looked at.
        case pageFocusingField

        /// The view that gets the field.
        var host: Host { self == .pageFocusingField ? .page : .tabView }
    }

    /// The two views that ask for the field (`searchField(_:on:)`): the tab view and the page.
    enum Host {
        case tabView
        case page
    }
}

extension View {
    /// The search field of `input` on this view when `MainTabs.searchField` puts it on `host`,
    /// otherwise the view as it is: the tab view and the search page both ask, one gets it.
    func searchField(_ input: SearchInput, on host: SearchInput.Host) -> some View {
        modifier(SearchFieldModifier(input: input, host: host))
    }
}

/// The field itself (`searchField(_:on:)`), with the prompt the page always had, on the view and
/// with the behaviour `MainTabs.searchField` names.
private struct SearchFieldModifier: ViewModifier {
    @Bindable var input: SearchInput
    var host: SearchInput.Host
    /// The field's focus with `.tabViewKeepingSearch`, mirrored in `input.isFocused`.
    @FocusState private var focused: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if host != MainTabs.searchField.host {
            content
        } else if MainTabs.searchField == .tabViewKeepingSearch {
            // Only the field: it becomes active when it is tapped, and the search stays as it is
            // while another tab is chosen (Apple's default activation). Never focused by hand:
            // iOS 26 shows the field in the bar, and the starting points are the empty page's.
            // Its focus is mirrored, so a route takes only the keyboard away (`leftInCode`).
            content
                .searchable(text: $input.text, isPresented: $input.isPresented, prompt: SearchView.prompt)
                .searchFocused($focused)
                .onChange(of: focused) { _, now in input.isFocused = now }
                .onChange(of: input.isFocused) { _, now in if !now { focused = false } }
        } else if MainTabs.searchField == .tabViewOpeningKeyboard {
            // The tab's selection and the field's activation go together (`.searchTabSelection`):
            // the keyboard comes every time the tab is chosen, also over an earlier query, and
            // closing the field goes back to the tab before and empties it (Apple: dismissing a
            // search clears its text).
            content
                .searchable(text: $input.text, isPresented: $input.isPresented, prompt: SearchView.prompt)
                .tabViewSearchActivation(.searchTabSelection)
        } else {
            // The field is shown and focused when the page opens with nothing typed; testers did
            // not find a hidden one.
            content
                .searchable(text: $input.text, isPresented: $input.isPresented, prompt: SearchView.prompt)
                .onAppear { if input.text.isEmpty { input.isPresented = true } }
        }
    }
}

/// One understood term of the query with its photo count: "Italien 230", "letzte Woche
/// 2.–8. Nov. 2026 14", a corrected typo with the typed word struck through, a term the
/// search had to leave out or a word it did not understand in grey.
struct SearchTokenChip: View {
    var token: SearchToken
    var dropped = false

    private var ignored: Bool { token.kind == .ignored }

    private var spoken: String {
        var parts = [token.label]
        if let detail = token.detail { parts.append(detail) }
        if let typed = token.typed { parts.append(String(localized: "korrigiert aus \(typed)")) }
        if ignored { parts.append(String(localized: "nicht erkannt")) }
        if dropped { parts.append(String(localized: "nicht berücksichtigt")) }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        let muted = ignored || dropped
        // Not the system grey: on its own 12 % capsule in caption size that was about 3.3:1
        // (design review W7); this grey keeps 4.5:1 and more.
        let tint: Color = muted ? Theme.secondaryText : Theme.accent
        HStack(spacing: 4) {
            Image(systemName: token.negated ? "minus.circle" : SearchView.symbol(token.kind))
                .imageScale(.small)
            if let typed = token.typed {
                Text(verbatim: typed).strikethrough().fontWeight(.regular)
            }
            Text(verbatim: token.label).strikethrough(muted)
            if let detail = token.detail {
                Text(verbatim: detail).fontWeight(.regular)
            }
            if let count = token.count, !ignored {
                Text(count.formatted()).fontWeight(.regular).monospacedDigit()
            }
        }
        .font(.caption.weight(.semibold))
        .compactLineLimit(1)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .foregroundStyle(tint)
        .background(tint.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
        .accessibilityValue(token.count.map { Text("\($0) \($0.formatted()) Fotos") } ?? Text(verbatim: ""))
        .accessibilityIdentifier(ignored ? "search.ignored" : "search.token")
    }
}

/// Simple wrapping layout for chips. A chip wider than the line (a long date range at the
/// accessibility text sizes) is measured at the line width, so it wraps inside its capsule
/// instead of running off the screen (design review W8).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = measure(subviews[index], width: bounds.width)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    /// Ideal size, or the size at the full line width when the ideal one does not fit.
    private func measure(_ subview: LayoutSubview, width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard width.isFinite, ideal.width > width else { return ideal }
        let wrapped = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: min(wrapped.width, width), height: wrapped.height)
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = measure(subviews[index], width: width)
            var row = rows[rows.count - 1]
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width && !row.indices.isEmpty {
                let y = row.y + row.height + spacing
                rows.append(Row(indices: [index], y: y, width: size.width, height: size.height))
                continue
            }
            row.indices.append(index)
            row.width = needed
            row.height = max(row.height, size.height)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
