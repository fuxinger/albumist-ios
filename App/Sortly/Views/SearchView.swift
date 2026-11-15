import SwiftUI
import SortlyCore
import SortlyEngine

/// Natural search over the analysed library (prompt §14), e.g. "Hunde Italien 2023".
/// Every search runs on a prepared index in a few milliseconds, so results follow the
/// typing; the chips show how the query was understood, with a photo count per term.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var result = SearchResult()
    /// The text `result` belongs to; the field runs ahead while a search is pending.
    @State private var resultQuery = ""
    @State private var searching = false
    /// Completions for the word being typed, from the user's own library.
    @State private var suggestions: [SearchSuggestion] = []
    /// Starting points for the empty field, from the user's own library.
    @State private var featured: [SearchSuggestion] = []
    @State private var detail: AssetFacts?
    /// The tapped thumbnail (a photo can be in the best hits and in the grid).
    @State private var zoomSource = ""
    @State private var addingToAlbum: [AssetID]?
    /// Thumbnails shown so far; the count and "Als Album anlegen" always cover every hit.
    @State private var shown = Self.page
    private static let page = 2_000
    /// The field is shown and focused when the tab opens; testers did not find a hidden one.
    @State private var searchActive = false
    @Namespace private var zoom

    /// Shown only before the library is analysed (afterwards the library's own starting points).
    private let examples: [String] = ["Strand 2024", "Italien", "Rechnungen", "Videos", "Nicht sortiert", "Screenshots Bestellung"]

    private var isEmptyQuery: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                if isEmptyQuery {
                    startingPoints
                } else {
                    if !suggestions.isEmpty { suggestionList }
                    if let rewrite = model.lastSearchRewrite, !searching {
                        Label("Verstanden als: \(rewrite)", systemImage: "apple.intelligence")
                            .font(.footnote).foregroundStyle(.secondary)
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
                            ProgressView().frame(maxWidth: .infinity)
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
        .sheet(item: $detail) { facts in
            AssetDetailView(facts: facts) { addingToAlbum = [facts.id] }
                .navigationTransition(.zoom(sourceID: zoomSource, in: zoom))
        }
        .sheet(isPresented: Binding(get: { addingToAlbum != nil }, set: { if !$0 { addingToAlbum = nil } })) {
            AddToAlbumSheet(assets: addingToAlbum ?? []) {}
        }
        .searchable(text: $query, isPresented: $searchActive,
                    prompt: SmartAssistant.isAvailable ? Text("z. B. Grillen bei Oma letzten Sommer") : Text("z. B. Hunde Italien 2023"))
        .onAppear { if query.isEmpty { searchActive = true } }
        // Starting points follow the library (a finished analysis brings places and topics).
        .task(id: model.facts.count) { featured = await model.featuredSearches() }
        .task(id: query) {
            let text = query
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                result = SearchResult(); resultQuery = ""; suggestions = []; searching = false
                return
            }
            searching = true
            // Completions right away; the search itself waits until typing pauses.
            suggestions = await model.searchSuggestions(for: text)
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let found = await model.search(text)
            guard !Task.isCancelled else { return }
            result = found
            resultQuery = text
            shown = Self.page
            searching = false
        }
    }

    // MARK: Parts

    private var startingPoints: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            Text("Suche nach Orten, Jahren, Themen oder Text auf Screenshots.")
                .foregroundStyle(.secondary)
            FlowLayout(spacing: Theme.Spacing.s) {
                if featured.isEmpty {
                    ForEach(examples, id: \.self) { example in
                        Button(example) { query = example }
                            .buttonStyle(.bordered)
                            .buttonBorderShape(.capsule)
                            .accessibilityIdentifier("search.example")
                    }
                } else {
                    ForEach(featured) { suggestion in
                        Button { query = suggestion.completion } label: {
                            Label(suggestion.label, systemImage: Self.symbol(suggestion.kind))
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .accessibilityValue(Text("\(suggestion.count) Fotos"))
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
                            .frame(width: 24)
                        Text(verbatim: suggestion.label)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(suggestion.count.formatted())
                            .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: suggestion.label))
                .accessibilityValue(Text("\(suggestion.count) Fotos"))
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("search.suggestion")
            }
        }
    }

    /// Nothing matched every term: the search left the least important ones out and says so.
    private var relaxedNote: some View {
        Label {
            Text("Kein Foto passt zu allen Begriffen. Ohne \(result.dropped.map(\.label).formatted(.list(type: .and))) gesucht.")
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("search.relaxed")
    }

    /// Never an unexplained empty page: says whether nothing was understood or which term
    /// has no photos at all.
    private var emptyState: some View {
        let understood = result.tokens.filter { $0.kind != .ignored }
        return Group {
            if understood.isEmpty {
                ContentUnavailableView("Nicht verstanden", systemImage: "questionmark.circle",
                                       description: Text("Suche nach Orten, Jahren, Themen oder Text auf Screenshots."))
            } else if let missing = understood.first(where: { $0.count == 0 }) {
                ContentUnavailableView("Keine Fotos", systemImage: "magnifyingglass",
                                       description: Text("Zu „\(missing.label)“ gibt es keine Fotos in deiner Mediathek."))
            } else {
                ContentUnavailableView.search(text: resultQuery)
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
            Text("\(result.ids.count.formatted()) Treffer").font(.footnote).foregroundStyle(.secondary).monospacedDigit()
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
            VStack(spacing: Theme.Spacing.s) {
                Text("\(shown.formatted()) von \(result.ids.count.formatted()) angezeigt")
                    .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                Button("Weitere Treffer anzeigen") { shown += Self.page }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("search.showMore")
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Theme.Spacing.s)
        }
    }

    private func thumbnail(_ id: AssetID, source: String) -> some View {
        let hit = model.factsByID[id]
        let key = source + ":" + id.rawValue
        return Button {
            zoomSource = key
            detail = hit
        } label: {
            AssetThumbnail(id: id, side: 110)
                .aspectRatio(1, contentMode: .fill)
                .matchedTransitionSource(id: key, in: zoom)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(hit == nil)
        .accessibilityLabel(Text(hit?.asset.creationDate?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "Foto")))
        .accessibilityIdentifier("search.result")
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
        if ignored { parts.append(String(localized: "Nicht verstanden")) }
        if dropped { parts.append(String(localized: "nicht berücksichtigt")) }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        let muted = ignored || dropped
        let tint: Color = muted ? .secondary : Theme.accent
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
        .accessibilityValue(token.count.map { Text("\($0) Fotos") } ?? Text(verbatim: ""))
        .accessibilityIdentifier(ignored ? "search.ignored" : "search.token")
    }
}

/// Simple wrapping layout for chips.
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
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
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
