import SwiftUI
import AlbumistCore

/// "Reise anpassen" (I07): a trip Albumist cut wrongly is split at a day or merged with the
/// trip right before or after it. The change is kept in time, so every later analysis holds
/// to it; it can be undone here, at the trip, or all at once in the settings.
///
/// The trip is shown as a timeline (design wave 3, DS-14): its days from top to bottom, each with
/// its date, where it was and larger photos, and the days without photos between them; the trips
/// right before and after it at its ends, each in a section of its own with the days between
/// (review G3), where merging joins them.
struct TripWorkshopView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Symbol columns grow with the text size, so a symbol never runs over its text (P3-12).
    @ScaledMetric(relativeTo: .body) private var changeSymbolWidth: CGFloat = 28
    var proposal: AlbumProposal
    /// Called once a change is stored: the suggestion this sheet came from goes away with the
    /// run that applies it, however the sheet is closed then.
    var onChanged: () -> Void

    private enum Outcome { case split, merged, undone }
    private enum Side { case before, after }

    @State private var splitIndex: Int?
    @State private var working: Outcome?
    @State private var done: Outcome?
    /// The change is saved and a longer run applies it (`TripWorkshop.AfterChange.savedForLater`).
    @State private var saved = false
    @State private var merging: Side?
    @State private var failed = false
    /// What the timeline shows (`TripTimeline.content`), made off the main thread once for the
    /// trip, its neighbours and the facts (review G6: the body worked it out at every tap); nil
    /// until it is first made.
    @State private var timeline: TripTimeline.Content?
    /// What `timeline` was made from: a merge row says the days between only from a timeline made
    /// with that neighbour (review M5: the gap to the trip before stood beside a new neighbour
    /// until its timeline came).
    @State private var timelineMadeFor: TimelineInputs?

    /// What the timeline is made from: the trip, the trips around it and the facts' revision (the
    /// photos' dates, places and ranks come from the facts).
    private struct TimelineInputs: Equatable {
        var trip: AlbumistID
        var photos: Int
        var before: AlbumistID?
        var after: AlbumistID?
        var facts: Int
    }

    /// The trip's days, for the header's count until the timeline is made.
    private var days: [TripWorkshop.Day] {
        TripWorkshop.days(of: proposal.assetIDs, dates: model.creationDates, calendar: .current)
    }

    var body: some View {
        let around = model.tripNeighbours(of: proposal)
        let inputs = TimelineInputs(trip: proposal.id, photos: proposal.assetIDs.count, before: around.before?.id,
                                    after: around.after?.id, facts: model.factsVersion)
        List {
            if let done {
                finished(done)
            } else if let working {
                Section {
                    HStack(spacing: Theme.Spacing.s) {
                        ProgressView()
                            .accessibilityHidden(true) // the text beside it says what runs
                        Text(working == .split ? "Albumist teilt die Reise und plant die Vorschläge neu …" : "Albumist plant deine Reisen und Vorschläge neu …")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                }
            } else {
                let mergeShown = around.before != nil || around.after != nil
                // Counted from the timeline once it is made: the body sorts no photos at a tap.
                header(timeline?.days.count ?? days.count)
                // While the changes wait, why is said once (review G4): under the first merge row
                // shown, else under these controls, also until the timeline with the merge rows is
                // made (review M5).
                changesSection(saysWhy: !mergeShown || timeline == nil)
                // The trip in the order of time (DS-14), each part a section under its own heading
                // (review G3): the trip before it, its days, the trip after it.
                if let timeline {
                    if let before = around.before {
                        neighbourSection(before, side: .before, gap: gap(to: before, side: .before), explains: true)
                    }
                    daysSection(timeline)
                    if let after = around.after {
                        neighbourSection(after, side: .after, gap: gap(to: after, side: .after), explains: around.before == nil)
                    }
                }
            }
        }
        .navigationTitle("Reise anpassen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // A round close button: the wider "Abbrechen" pushed the title off centre. Also while
            // the sheet waits for the run and once a change is saved: the change is stored, so
            // closing loses nothing (re-review of 7e8aba3: a long check that started fresh read as
            // short and held the sheet). Only the applied change's result leads on with
            // "Zu den Reisen".
            ToolbarItem(placement: .cancellationAction) {
                if done == nil || saved {
                    Button { dismiss() } label: { Label("Schließen", systemImage: "xmark") }
                }
            }
        }
        // The chosen split and its button stay in reach while the days scroll; it splits at the
        // day shown.
        .safeAreaInset(edge: .bottom) {
            if done == nil, working == nil, let index = splitIndex, let entries = timeline?.days,
               let preview = TripWorkshop.split(entries.map(\.day), before: index, dates: model.creationDates) {
                splitBar(preview, day: entries[index].day)
                    .motionAwareTransition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // The timeline, made off the main thread (review G6): again for other trips around it or
        // new facts. A day chosen on the timeline of before is let go when the days moved.
        .task(id: inputs) {
            let made = await model.tripTimeline(of: proposal, before: around.before, after: around.after)
            guard !Task.isCancelled else { return }
            if made.days.map(\.id) != timeline?.days.map(\.id) { splitIndex = nil }
            timeline = made
            timelineMadeFor = inputs
        }
        // The controls grey and the note comes while the changes wait, and both go back by
        // themselves when the run ends (they follow the model).
        .animation(reduceMotion ? nil : .smooth, value: model.tripChangeWait)
        // The change shows once the trips on screen include it (`TripChangeLedger`), not when
        // the run ends: its end refreshes the overview after, and a run that slipped in read the
        // trips from before. Saved when no run that read it is left (paused, ended early).
        .onChange(of: model.tripChangeState) { _, state in
            // Saved, and the trips shown include it now (a refresh landed after all, or the run
            // that applies it ended while the sheet was open): said as made.
            if state == .applied, saved, done != nil {
                withAnimation(.smooth) { saved = false }
                return
            }
            guard state != .waiting, let finished = working else { return }
            withAnimation(.smooth) {
                working = nil
                saved = state == .savedForLater
                done = finished
            }
        }
        .alert("Gerade nicht möglich", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Albumist analysiert oder ändert gerade deine Mediathek. Versuche es gleich noch einmal.")
        }
    }

    /// An analysis runs (each change starts one) or albums are made: the changes wait, and
    /// `TripChangeWaitNote` says so next to them.
    private var busy: Bool { model.tripChangeWait != nil }

    /// The sheet waits only for a short check, the run a change starts after a complete
    /// analysis. A change during a Pause starts the run that goes on with the paused analysis
    /// (decision 18.11.2026), which can take tens of minutes: the change is saved, the sheet says
    /// so and can be closed (review of 163d656: it waited with no way to close).
    private func perform(_ outcome: Outcome, _ change: @escaping @MainActor () async -> Bool) {
        Task {
            if await change() {
                onChanged()
                switch model.afterTripChange {
                case .waitHere:
                    withAnimation(.smooth) { working = outcome }
                case .savedForLater:
                    withAnimation(.smooth) {
                        saved = true
                        done = outcome
                    }
                }
            } else {
                failed = true
            }
        }
    }

    // MARK: Sections

    /// The trip's name, its `count` of days and its photos, and what the sheet is for.
    private func header(_ count: Int) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                let dayCount = Text("\(count) Tage")
                let photoCount = Text("\(proposal.assetIDs.count) \(proposal.assetIDs.count.formatted()) Fotos mit Ort")
                Text(title(proposal)).font(.headline)
                Text("\(dayCount) · \(photoCount)")
                    .font(.subheadline).foregroundStyle(.noteText)
                Text("""
                    Hat Albumist hier zwei Reisen zusammengefasst oder eine Reise zerschnitten? Das korrigierst du hier. \
                    Albumist merkt es sich auch für jede spätere Analyse.
                    """)
                    .font(.footnote).foregroundStyle(.noteText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    /// What the user changed at this trip before, each with "Rückgängig machen" (P3-09: "Aufheben"
    /// was a fourth word for it). `saysWhy`: no merge rows follow, so this footer says why it waits.
    @ViewBuilder
    private func changesSection(saysWhy: Bool) -> some View {
        let changes = model.tripChanges(around: proposal)
        if !changes.isEmpty {
            Section {
                ForEach(changes, id: \.self) { change in
                    HStack(spacing: Theme.Spacing.s) {
                        Image(systemName: change.isSplit ? "scissors" : "arrow.triangle.merge")
                            .foregroundStyle(Theme.accent)
                            .frame(width: changeSymbolWidth)
                            .accessibilityHidden(true)
                        Text(describe(change))
                        Spacer(minLength: Theme.Spacing.s)
                        Button {
                            perform(.undone) { await model.undoTripChange(change) }
                        } label: {
                            Text("Rückgängig machen")
                                .font(.subheadline.weight(.semibold))
                                .frame(minWidth: 44, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .disabled(busy)
                        .tripChangeWaitHint(model.tripChangeWait)
                        .accessibilityIdentifier("workshop.undoChange")
                    }
                }
            } header: {
                Text("Deine Änderungen")
            } footer: {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    if saysWhy { TripChangeWaitNote() }
                    Text("Machst du eine Änderung rückgängig, erkennt Albumist diese Reisen wieder selbst.")
                    // During a Pause the undo starts the analysis again (decision 18.11.2026).
                    if model.analysis.isPausedByUser {
                        Text("Die pausierte Analyse läuft dann weiter.")
                    }
                }
            }
        }
    }

    /// The trip's days as a timeline (DS-14, `TripTimeline`): each with where it was and its
    /// photos, and the days without photos between them. A tap on a day after the first chooses
    /// it as the start of the second trip (the bar below says what the split makes, "Reise teilen"
    /// does it); the line breaks there, with scissors. The heading and the hint belong to the days
    /// (review G3); a trip of one day cannot be split and stands under "Diese Reise", between
    /// "Reise davor" and "Reise danach".
    @ViewBuilder
    private func daysSection(_ timeline: TripTimeline.Content) -> some View {
        let entries = timeline.days
        Section {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                let lines = TripTimeline.lines(entries, at: index, cut: splitIndex)
                if entry.quietDaysBefore > 0 {
                    TripTimelineGapRow(text: Text("\(entry.quietDaysBefore) \(entry.quietDaysBefore.formatted()) Tage ohne Fotos"),
                                       line: lines.gap)
                        .tripTimelineRow()
                }
                dayRow(entry, index: index, lines: lines)
            }
        } header: {
            if timeline.days.count > 1 {
                Text("An einem Tag teilen")
            } else {
                Text("Diese Reise")
            }
        } footer: {
            if timeline.days.count > 1 {
                Text("Tippe auf den Tag, an dem die zweite Reise beginnt.")
            }
        }
    }

    /// One day on the timeline: a button that chooses it as the start of the second trip, except
    /// the first ("Beginn der Reise"). The line as `TripTimeline.lines` draws it: broken where the
    /// second trip begins, dotted over days without photos.
    @ViewBuilder
    private func dayRow(_ entry: TripTimeline.Day, index: Int, lines: TripTimeline.Lines) -> some View {
        let selected = splitIndex == index
        if entry.canStartNewTrip {
            Button {
                withAnimation(.smooth(duration: 0.25)) { splitIndex = splitIndex == index ? nil : index }
            } label: {
                TripTimelineDayRow(entry: entry, note: selected ? String(localized: "Neue Reise ab hier") : nil,
                                   selected: selected, above: lines.above, below: lines.below)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workshop.day")
            .accessibilityHint(Text("Neue Reise ab diesem Tag"))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .tripTimelineRow()
        } else {
            TripTimelineDayRow(entry: entry, note: String(localized: "Beginn der Reise"), selected: false, above: lines.above, below: lines.below)
                .tripTimelineRow()
        }
    }

    /// The two trips the chosen split makes, and the button, above the home indicator.
    private func splitBar(_ preview: TripWorkshop.Split, day: TripWorkshop.Day) -> some View {
        let minimum = model.settings.trips.minPhotos
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text("Daraus werden zwei Reisen").font(.subheadline.weight(.semibold))
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                PartRow(number: 1, part: preview.first)
                PartRow(number: 2, part: preview.second)
            }
            if preview.first.count < minimum || preview.second.count < minimum {
                Text("Ein Teil hat weniger als \(minimum) Fotos mit Ort. Er wird kein eigener Reise-Vorschlag; seine Fotos bleiben in den Länder- und Orte-Alben.")
                    .font(.footnote).foregroundStyle(.noteText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                perform(.split) { await model.splitTrip(at: day) }
            } label: {
                Label("Reise teilen", systemImage: "scissors")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(busy)
            .tripChangeWaitHint(model.tripChangeWait)
            .accessibilityIdentifier("workshop.split")
            // The bar covers the end of the list, so it says itself why the button waits.
            TripChangeWaitNote(identifier: "workshop.split.busyNote")
            // During a Pause the split starts the analysis again (decision 18.11.2026).
            if model.analysis.isPausedByUser {
                Text("Die pausierte Analyse läuft dann weiter.")
                    .font(.footnote).foregroundStyle(.noteText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Spacing.m)
        .floatingPanel()
        .padding(.horizontal, Theme.Spacing.m)
        .padding(.bottom, Theme.Spacing.s)
    }

    /// A neighbouring trip at an end of the timeline (the one before at the top, the one after at
    /// the bottom), in a section under a heading of its own (review G3): its cover, its name, its
    /// photos and the days without photos between, and merging with it after the question.
    /// `explains`: the first one shown says under itself why the merge rows wait, while they wait,
    /// and what merging is for, once for both (review G4: with a trip on both sides it was said
    /// twice, under one identifier).
    private func neighbourSection(_ other: AlbumProposal, side: Side, gap: Int?, explains: Bool) -> some View {
        Section {
            mergeButton(other, side: side, gap: gap)
        } header: {
            if side == .before {
                Text("Reise davor")
            } else {
                Text("Reise danach")
            }
        } footer: {
            if explains {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    TripChangeWaitNote()
                    Text("Für eine Reise mit Pause, zum Beispiel ein Wochenende zu Hause zwischen zwei Stationen.")
                }
            }
        }
    }

    /// The days without photos between this trip and `other`, its neighbour on `side`, from the
    /// timeline made with that neighbour there: nil while the timeline shown was made for another
    /// trip or neighbour, so a merge row never says the days to a trip it is not about (review
    /// M5). A new revision of the facts alone keeps the days shown until the new timeline comes.
    private func gap(to other: AlbumProposal, side: Side) -> Int? {
        guard let timeline, let made = timelineMadeFor, made.trip == proposal.id,
              made.photos == proposal.assetIDs.count else { return nil }
        switch side {
        case .before: return made.before == other.id ? timeline.quietDaysFromBefore : nil
        case .after: return made.after == other.id ? timeline.quietDaysToAfter : nil
        }
    }

    /// "Mit der Reise davor/danach zusammenlegen": the other trip's cover, name and photos, and
    /// the days without photos a merge bridges ("3 Tage dazwischen", `gap`).
    private func mergeButton(_ other: AlbumProposal, side: Side, gap: Int?) -> some View {
        let photos = Text("\(other.assetIDs.count) \(other.assetIDs.count.formatted()) Fotos")
        let detail: Text
        if let gap, gap > 0 {
            let between = Text("\(gap) \(gap.formatted()) Tage dazwischen")
            detail = Text("\(title(other)) · \(photos) · \(between)")
        } else {
            detail = Text("\(title(other)) · \(photos)")
        }
        return Button {
            merging = side
        } label: {
            MergeRowLabel(title: side == .before ? "Mit der Reise davor zusammenlegen" : "Mit der Reise danach zusammenlegen",
                          detail: detail,
                          coverIDs: model.proposalCoverIDs(for: other), hidesPreview: model.previewHidden(for: other))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .tripChangeWaitHint(model.tripChangeWait)
        .accessibilityIdentifier(side == .before ? "workshop.merge.before" : "workshop.merge.after")
        .confirmationDialog("Zu einer Reise zusammenlegen?", isPresented: Binding(get: { merging == side }, set: { if !$0 { merging = nil } }),
                            titleVisibility: .visible) {
            Button("Zusammenlegen") {
                let (first, second) = side == .before ? (other, proposal) : (proposal, other)
                perform(.merged) { await model.mergeTrips(first, second) }
            }
        } message: {
            // The earlier trip first, as in the trip list read from the past. During a Pause the
            // merge starts the analysis again (decision 18.11.2026): said before the tap.
            let (first, second) = side == .before ? (other, proposal) : (proposal, other)
            let total = other.assetIDs.count + proposal.assetIDs.count
            if model.analysis.isPausedByUser {
                Text("„\(title(first))“ und „\(title(second))“ werden eine Reise mit \(total) \(total.formatted()) Fotos. Die pausierte Analyse läuft dann weiter.")
            } else {
                Text("„\(title(first))“ und „\(title(second))“ werden eine Reise mit \(total) \(total.formatted()) Fotos.")
            }
        }
    }

    @ViewBuilder
    private func finished(_ outcome: Outcome) -> some View {
        Section {
            VStack(spacing: Theme.Spacing.s) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.bounce, value: done != nil)
                    .accessibilityHidden(true)
                if saved {
                    // Not applied yet: the run that goes on with the analysis does it.
                    Text("Gespeichert. Albumist wendet die Änderung an, sobald die Analyse fertig ist.")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Group {
                        switch outcome {
                        case .split: Text("Aus einer Reise sind zwei geworden.")
                        case .merged: Text("Die zwei Reisen sind jetzt eine.")
                        case .undone: Text("Deine Änderung ist rückgängig gemacht.")
                        }
                    }
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    Group {
                        if outcome == .undone {
                            Text("Albumist erkennt diese Reisen wieder selbst. Die Vorschläge sind schon angepasst.")
                        } else {
                            Text("Die Vorschläge sind schon angepasst. Albumist hält sich daran, auch bei jeder neuen Analyse. Rückgängig machen kannst du es hier an der Reise oder in den Einstellungen.")
                        }
                    }
                    .font(.subheadline).foregroundStyle(.noteText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.s)
        }
        Section {
            Button("Zu den Reisen") {
                dismiss()
                onChanged()
            }
            .buttonStyle(PrimaryButtonStyle())
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
            .accessibilityIdentifier("workshop.done")
        }
    }

    private func title(_ proposal: AlbumProposal) -> String {
        model.userTitles[proposal.id] ?? proposal.title
    }

    private func describe(_ change: TripChange) -> String {
        switch change {
        case .split(let date):
            let day = date.formatted(.dateTime.weekday(.wide).day().month(.wide))
            return String(localized: "Geteilt: neue Reise ab \(day)")
        case .merge(let interval):
            let span = PartRow.span(interval.start, interval.end)
            return String(localized: "Zusammengelegt: \(span)")
        }
    }
}

/// Why splitting, merging, "Aufheben" and "Reisen wieder automatisch erkennen" wait, under the
/// controls it explains: a small spinner and one sentence, only while they wait
/// (`AppModel.tripChangeWait`). Controls and note follow the model, so both come back by
/// themselves when the run ends (UI run 44375768011: right after a split the merge row was off,
/// looked tappable and said nothing).
struct TripChangeWaitNote: View {
    @Environment(AppModel.self) private var model
    var identifier = "workshop.busyNote"

    var body: some View {
        if let wait = model.tripChangeWait {
            Label {
                Text(Self.reason(wait))
            } icon: {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true) // the text beside it says what runs
            }
            .font(.footnote)
            .foregroundStyle(.noteText)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(identifier)
        }
    }

    static func reason(_ wait: TripWorkshop.Wait) -> LocalizedStringKey {
        switch wait {
        case .tripsAgain: LocalizedStringKey("Albumist rechnet die Reisen gerade neu. Gleich wieder möglich.")
        // The first analysis or one that goes on can take long: no "gleich".
        case .analysis: LocalizedStringKey("Albumist analysiert gerade deine Fotos. Danach wieder möglich.")
        case .creatingAlbums: LocalizedStringKey("Albumist legt gerade Alben an. Danach wieder möglich.")
        }
    }
}

extension View {
    /// While trip changes wait, VoiceOver says why on the greyed control itself, not only in the
    /// note under it (the reason of `TripChangeWaitNote`); no hint otherwise.
    func tripChangeWaitHint(_ wait: TripWorkshop.Wait?) -> some View {
        accessibilityHint(wait.map { Text(TripChangeWaitNote.reason($0)) } ?? Text(verbatim: ""))
    }
}

private extension TripChange {
    var isSplit: Bool {
        if case .split = self { return true }
        return false
    }
}

/// "Mit der Reise davor/danach zusammenlegen" beside the other trip's cover (DS-14): in the
/// accent while it can be tapped, in the system's greys while it waits (a plain button keeps the
/// colours it is given), the cover dimmed then. The cover never shows a sensitive photo
/// (`proposalCoverIDs`), "Vorschau ausgeblendet" for a trip of nothing but sensitive ones; as
/// large as the covers of the history and the receipt and growing with the text up to the same
/// point (`AlbumRowCover`, review G8); at the accessibility text sizes a wide strip above the
/// words.
private struct MergeRowLabel: View {
    var title: LocalizedStringKey
    var detail: Text
    var coverIDs: [AssetID]
    var hidesPreview: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        AdaptiveStack(horizontalAlignment: .leading, verticalAlignment: .top, spacing: Theme.Spacing.m) {
            AlbumRowCover(ids: coverIDs, hidesPreview: hidesPreview, placeholderSymbol: "airplane")
                .opacity(isEnabled ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text(title)
                } icon: {
                    Image(systemName: "arrow.triangle.merge")
                        .accessibilityHidden(true)
                }
                .font(.body.weight(.semibold))
                .foregroundStyle(isEnabled ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                detail
                    .font(.subheadline)
                    .foregroundStyle(isEnabled ? AnyShapeStyle(.noteText) : AnyShapeStyle(.tertiary))
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.vertical, Theme.Spacing.xs)
        .contentShape(Rectangle())
    }
}

/// One of the two trips a split makes.
private struct PartRow: View {
    var number: Int
    var part: TripWorkshop.Part

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            Text(number.formatted())
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 24, height: 24)
                .background(Theme.accent, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.span(part.start, part.end)).font(.subheadline)
                Text("\(part.count) \(part.count.formatted()) Fotos").font(.footnote).foregroundStyle(.noteText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// "12.–14. Mai 2024", or one day.
    static func span(_ start: Date, _ end: Date) -> String {
        if Calendar.current.isDate(start, inSameDayAs: end) || end <= start {
            return start.formatted(.dateTime.day().month(.wide).year())
        }
        return (start..<end).formatted(.interval.day().month(.wide).year())
    }
}
