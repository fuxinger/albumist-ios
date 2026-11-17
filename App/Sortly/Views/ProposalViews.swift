import SwiftUI
import SortlyCore
import SortlyEngine

/// List of proposals, optionally for one area.
struct ProposalListView: View {
    @Environment(AppModel.self) private var model
    @Environment(Navigator.self) private var navigator: Navigator?
    var area: OrganizationArea?

    private var proposals: [AlbumProposal] {
        model.proposals
            .filter { area == nil || $0.kind.area == area }
            // The app's one suggestion order (also used by "Dein Startpaket" and the preview).
            .inDisplayOrder()
    }

    /// Suggestions grouped by area in the app's area order; trips newest first.
    private struct AreaSection: Identifiable {
        let area: OrganizationArea
        let items: [AlbumProposal]
        var id: OrganizationArea { area }
    }

    private var sections: [AreaSection] {
        let groups = Dictionary(grouping: proposals) { $0.kind.area }
        return OrganizationArea.allCases.compactMap { area in
            groups[area].map { AreaSection(area: area, items: $0) }
        }
    }

    private func rows(_ items: [AlbumProposal]) -> some View {
        ForEach(items) { proposal in
            // Pushed by value (`AppScreen`): the suggestion may push its own preview.
            PushLink(.proposal(ProposalRef(proposal))) {
                ProposalRow(proposal: proposal)
            }
        }
    }

    /// Open suggestions that may be accepted in one go: the same safe list as "Dein Startpaket"
    /// (`ProposalDecision.isSafeToAcceptUnseen`; never sensitive ones, prompt §8, and no
    /// possible match, review 16.11.).
    private var recommendable: [AlbumProposal] {
        proposals.filter { p in
            model.decisions[p.id] == nil && ProposalDecision.isSafeToAcceptUnseen(p, match: model.match(for: p))
        }
    }

    var body: some View {
        List {
            if proposals.isEmpty {
                ContentUnavailableView("Keine Vorschläge", systemImage: "checkmark.circle",
                                       description: Text("Für diesen Bereich gibt es gerade nichts zu tun."))
            }
            if !recommendable.isEmpty {
                Section {
                    Button { acceptRecommended() } label: { Text("\(recommendable.count) empfohlene auswählen") }
                        .buttonStyle(PrimaryButtonStyle())
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                } footer: {
                    Text("Empfohlen sind sichere und wahrscheinliche Vorschläge ohne persönliche Themen. Angelegt wird erst, wenn du in der Vorschau bestätigst. Dort siehst du jedes Album noch einmal.")
                }
            }
            if area == nil {
                // All suggestions: one section per area, so a trip "Rom · 10.05.–14.05.2024"
                // is not mistaken for a city album next to the countries (Fuchs, 14.11.).
                ForEach(sections) { section in
                    Section {
                        rows(section.items)
                    } header: {
                        Text(section.area.title)
                    }
                }
            } else {
                rows(proposals)
            }
        }
        .navigationTitle(area?.title ?? "Vorschläge")
        // Accepted suggestions are created together: the way there is always in reach.
        .safeAreaInset(edge: .bottom) {
            if !model.proposalsToApply.isEmpty {
                Button {
                    Navigator.push(.plan, on: navigator)
                } label: {
                    Text("\(model.proposalsToApply.count) ausgewählte Alben anlegen")
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.bottom, Theme.Spacing.s)
            }
        }
    }

    private func acceptRecommended() {
        let accepted = recommendable
        for p in accepted { model.setDecision(model.recommendedDecision(for: p), for: p) }
        AccessibilityNotification.Announcement(String(localized: "\(accepted.count) Vorschläge ausgewählt")).post()
    }
}

struct ProposalRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    var proposal: AlbumProposal

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            AssetThumbnail(id: proposal.coverAssetID ?? AssetID(""), side: 56)
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(model.userTitles[proposal.id] ?? proposal.title).font(.body.weight(.medium)).lineLimit(typeSize.isAccessibilitySize ? 5 : 2)
                // "Fotos" everywhere, not "Aufnahmen", "Bilder" or "Medien" (design review W4).
                Text("\(proposal.assetIDs.count - (model.removedFromProposals[proposal.id]?.count ?? 0)) Fotos").font(.footnote).foregroundStyle(.secondary)
                if proposal.requiresUserName && model.userTitles[proposal.id] == nil {
                    // A place only the user can name: says what is missing instead of
                    // "Neues Album" (first device test 15.11.: 44 "Häufiger Ort N").
                    // The app's warning colour: system orange on its 12 % badge was about 2:1
                    // in light mode (design review D1); this one is 5.0–7.6:1.
                    StatusBadge(text: "Name fehlt", tint: Theme.tint(for: .documents))
                } else if let status = model.match(for: proposal)?.status {
                    StatusBadge(text: status.label, tint: status.tint)
                }
                decisionLabel
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    /// The decision in words, not only as a small symbol (testers missed the check mark).
    @ViewBuilder
    private var decisionLabel: some View {
        switch model.decisions[proposal.id] {
        case .reject:
            Label("Nicht jetzt", systemImage: "xmark.circle")
                .labelStyle(CompactLabelStyle())
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        case .some(let d) where d.isAccepted:
            Label("Ausgewählt", systemImage: "checkmark.circle.fill")
                .labelStyle(CompactLabelStyle())
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.accent)
        default:
            EmptyView()
        }
    }
}

/// One proposal with its evidence and the existing-album comparison (prompt §5).
struct ProposalDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var proposal: AlbumProposal
    @State private var name = ""
    @State private var showAdjust = false
    @State private var suggesting = false
    @Environment(Navigator.self) private var navigator: Navigator?
    /// The preview of "Album anlegen", pushed onto the stack's path (`AppScreen`).
    @State private var directPlan: PlanToken?
    /// A preview of "Album anlegen" that was ready while another tab was chosen: offered again
    /// when this tab shows (`showWaiting()`). Its pick for the preview is undone while it waits,
    /// so nothing stays selected that the user did not choose.
    @State private var waiting: WaitingPlan?
    /// "Album anlegen" is making its preview. The photos do not open meanwhile (the preview
    /// would be pushed above them), and nothing the plan is made from can be changed here: the
    /// name, the album ("Anpassen", "passt nicht"), the trip or the place.
    @State private var preparing = false
    @State private var applied = false
    @State private var rejectingMatch = false
    /// Set by "Album anlegen" for its preview only; undone when the user comes back without creating.
    @State private var previewSelection: AppModel.PreviewSelection?
    @State private var explainReliability = false
    @State private var showWorkshop = false
    /// Set when the trip was split or merged: this suggestion is gone, back to the list.
    @State private var reshaped = false
    @State private var confirmOftenHere = false

    /// Only trips get a creative name; places and dates keep their exact titles.
    private var canSuggestTitle: Bool {
        if case .trip = proposal.kind { return SmartAssistant.isAvailable && recommended.isCreatingNew }
        return false
    }

    private func suggestTitle() async {
        suggesting = true
        defer { suggesting = false }
        let details = proposal.reasons.map { ReasonText.text($0) }
        guard let title = await SmartAssistant.tripTitle(currentTitle: proposal.title, details: details, language: model.settings.titleLanguage) else { return }
        let year = proposal.dateRange.map { String(Calendar.current.component(.year, from: $0.start)) }
        model.setUserTitle([title, year].compactMap { $0 }.joined(separator: " "), for: proposal)
    }

    private var match: MatchResult? { model.match(for: proposal) }
    /// What the primary button does: the user's choice from "Anpassen" wins over Albumist's
    /// recommendation (it must never be overwritten by accepting the suggestion).
    private var recommended: ProposalDecision {
        let chosen = model.decision(for: proposal)
        if chosen.isAccepted { return chosen }
        return ProposalDecision.recommended(for: proposal, match: match, userTitle: name)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                // Two rows: with more, the actions fell below the tab bar on a 6.1" iPhone.
                // Spread over the whole time span, oldest first; a tap shows all photos.
                NavigationLink {
                    ProposalPhotosView(proposal: proposal)
                } label: {
                    ThumbnailGrid(ids: model.previewIDs(for: proposal), total: model.members(of: proposal).count, columns: 4, limit: 8,
                                  portrait: [.screenshots, .documents, .messenger].contains(proposal.kind.area))
                }
                .buttonStyle(.plain)
                .disabled(preparing)
                .accessibilityLabel(Text("Alle \(model.members(of: proposal).count) Fotos ansehen"))
                // The cover's colours glow behind the photos and end just below them, so the
                // text under them sits on the plain background. Behind the text, XCTest's
                // contrast audit kept failing clearly readable lines (8.9:1 measured in the
                // screenshot) whatever the wash's colours were: "31 photos in Italien.",
                // "LÄNDER UND ORTE · SICHER" (UI runs 2-4, 43773339053, 43779950348).
                .background(alignment: .top) {
                    PhotoGlow(id: model.previewIDs(for: proposal, count: 1).first ?? proposal.coverAssetID)
                        .padding(.horizontal, -Theme.Spacing.l)
                        .padding(.top, -240)
                        .padding(.bottom, -Theme.Spacing.s)
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    // Tapping the label explains what "Sicher" or "Wahrscheinlich" means.
                    Button { explainReliability = true } label: {
                        // The measured grey keeps 4.5:1 on any background; the
                        // symbol alone carries the accent (design review W18). 44 pt to tap (W9).
                        HStack(spacing: 4) {
                            Text("\(Text(proposal.kind.area.title)) · \(Text(proposal.reliability.label))")
                                .textCase(.uppercase)
                                .foregroundStyle(Theme.secondaryText)
                            Image(systemName: "info.circle")
                                .foregroundStyle(Theme.accent)
                        }
                        .font(.footnote.weight(.semibold))
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text(proposal.reliability.explanation))
                    .popover(isPresented: $explainReliability) {
                        Text(proposal.reliability.explanation)
                            .font(.subheadline)
                            .padding()
                            .frame(idealWidth: 300)
                            .fixedSize(horizontal: false, vertical: true)
                            .presentationCompactAdaptation(.popover)
                    }
                    if proposal.requiresUserName {
                        TextField(proposal.title, text: $name)
                            .font(.title2.weight(.bold))
                            .textFieldStyle(.roundedBorder)
                            .disabled(preparing)
                        Text("Gib diesem Ort oder dieser Gruppe einen Namen. Albumist benennt persönliche Orte nie selbst.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text(model.userTitles[proposal.id] ?? proposal.title).font(.title2.weight(.bold))
                        if canSuggestTitle {
                            Button {
                                Task { await suggestTitle() }
                            } label: {
                                if suggesting {
                                    ProgressView().controlSize(.small)
                                        .accessibilityLabel(Text("Name wird vorgeschlagen"))
                                } else {
                                    Label("Namen vorschlagen", systemImage: "apple.intelligence")
                                }
                            }
                            .font(.subheadline.weight(.semibold))
                            .disabled(suggesting || preparing)
                        }
                    }
                    ForEach(Array(proposal.reasons.enumerated()), id: \.offset) { _, reason in
                        Text(ReasonText.text(reason)).font(.subheadline).foregroundStyle(Theme.secondaryText) // below the photo glow, on the plain background
                    }
                }

                // Asked once per place, before the user decides on the album: the answer may
                // turn the trips there into one album of the place.
                if let question = model.recurringPlaceQuestion(for: proposal) {
                    recurringPlaceCard(question)
                }

                // Album status and destination folder in one card.
                Card {
                    matchContent
                    if match != nil { Divider() }
                    LabeledContent("Ordner", value: ([model.settings.rootFolderTitle] + proposal.folderPath)
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " › "))
                    if !proposal.optionalAssetIDs.isEmpty {
                        // Says what the number is (design review N5: "Nur vorgeschlagen: 12").
                        LabeledContent("Vielleicht passend") { Text("\(proposal.optionalAssetIDs.count) Fotos") }
                    }
                    if proposal.isSensitive {
                        Label("Persönlicher Inhalt: wird nie automatisch ausgewählt.", systemImage: "lock")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                actions

                // Reise-Werkstatt (I07): only before Albumist made the trip's album.
                if model.canReshape(proposal) {
                    Button { showWorkshop = true } label: {
                        Label("Reise teilen oder zusammenlegen", systemImage: "scissors")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(preparing)
                    .accessibilityIdentifier("proposal.reshapeTrip")
                }

                // The same answer without being asked: for a place visited too rarely for the
                // question (a semester abroad, a new second home).
                if model.recurringPlaceQuestion(for: proposal) == nil && model.canMarkRecurringPlace(proposal) {
                    Button { confirmOftenHere = true } label: {
                        Label("Keine Reise, hier bin ich öfter", systemImage: "mappin.and.ellipse")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(!model.canChangeHome || preparing)
                    .accessibilityIdentifier("proposal.oftenHere")
                    .confirmationDialog("Keine Reise?", isPresented: $confirmOftenHere, titleVisibility: .visible) {
                        Button("Keine Reise, hier bin ich öfter") { answerOftenHere(true) }
                    } message: {
                        Text("Aufenthalte an diesem Ort werden keine Reisen mehr, auch bei jeder neuen Analyse. Albumist schlägt stattdessen ein Album für den Ort vor. Zurücknehmen kannst du das in den Einstellungen.")
                    }
                    // Why it waits, as on the question card.
                    if let reason = oftenHereWaitReason(askedOnTheCard: false) {
                        Text(reason)
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Theme.Spacing.l)
        }
        // Each suggestion gets its own soft colours from its cover photo: behind the photos above.
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle("Vorschlag")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            name = model.userTitles[proposal.id] ?? ""
            showWaiting()
        }
        // The tab shows again (`Navigator.appearances`): a result that waited is offered now.
        .onChange(of: navigator?.appearances) { showWaiting() }
        .sheet(isPresented: $showAdjust) {
            NavigationRoot { AdjustProposalView(proposal: proposal) }
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showWorkshop, onDismiss: { if reshaped { dismiss() } }) {
            NavigationRoot { TripWorkshopView(proposal: proposal) { reshaped = true } }
        }
        .onChange(of: model.execution.finished) { _, finished in
            if showsDirect && finished != nil { applied = true }
        }
        .onChange(of: showsDirect) { _, showing in
            guard !showing else { return }
            if applied {
                // Back from the finished preview: the suggestion is done, return to the list.
                dismiss()
            } else if let selection = previewSelection {
                // Back without creating: the suggestion is not selected.
                model.endPreview(selection)
            }
            previewSelection = nil
            directPlan = nil
        }
    }

    /// "Bist du hier öfter?": the user's answer is the only thing that says what a place is
    /// to them, and it is never shown as a title.
    private func recurringPlaceCard(_ question: RecurringPlaceCandidate) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Bist du hier öfter, etwa Zweitwohnsitz, Arbeit oder Familie?").font(.headline)
                Text("Du warst \(question.stayCount)-mal hier, zuletzt \(question.lastVisit.formatted(.dateTime.month(.wide).year())).")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Button("Ja, hier bin ich öfter") { answerOftenHere(true) }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(!model.canChangeHome || preparing)
                .accessibilityIdentifier("proposal.oftenHere.yes")
            Button("Nein, das sind Reisen") { answerOftenHere(false) }
                .buttonStyle(SecondaryButtonStyle())
                // While a change in "Dein Zuhause" is applied, like "Ja": the answer would be
                // stored beside it and the question come back until the suggestions are new.
                .disabled(model.homeChangeRunning || preparing)
                .accessibilityIdentifier("proposal.oftenHere.no")
            // Why a button waits (design review N8 found the two buttons behaving differently
            // without a word why): "Ja" plans the trips anew, "Nein" changes nothing.
            if let reason = oftenHereWaitReason(askedOnTheCard: true) {
                Text(reason)
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Why "Ja, hier bin ich öfter" on the question card (and during a change in "Dein
    /// Zuhause" also "Nein"), or "Keine Reise, hier bin ich öfter" on a trip, waits; nil when it
    /// can be tapped.
    private func oftenHereWaitReason(askedOnTheCard: Bool) -> LocalizedStringKey? {
        if model.homeChangeRunning {
            return LocalizedStringKey("Gleich wieder möglich: Albumist passt gerade die Vorschläge an deine Änderung in „Dein Zuhause“ an.")
        }
        if model.analysisResetting {
            return askedOnTheCard
                ? LocalizedStringKey("„Ja“ geht, sobald die Analyse neu aufgebaut ist, denn danach plant Albumist deine Reisen neu.")
                : LocalizedStringKey("„Keine Reise“ geht, sobald die Analyse neu aufgebaut ist, denn danach plant Albumist deine Reisen neu.")
        }
        if model.execution.isRunning {
            return askedOnTheCard
                ? LocalizedStringKey("„Ja“ geht, sobald das Anlegen fertig ist, denn danach plant Albumist deine Reisen neu.")
                : LocalizedStringKey("„Keine Reise“ geht, sobald das Anlegen fertig ist, denn danach plant Albumist deine Reisen neu.")
        }
        if model.analysis.isRunning {
            return askedOnTheCard
                ? LocalizedStringKey("„Ja“ geht, sobald die Analyse fertig ist, denn danach plant Albumist deine Reisen neu.")
                : LocalizedStringKey("„Keine Reise“ geht, sobald die Analyse fertig ist, denn danach plant Albumist deine Reisen neu.")
        }
        return nil
    }

    /// A "Ja" makes this suggestion go away when the suggestions are made again (like every
    /// change in "Dein Zuhause"): back to the list.
    private func answerOftenHere(_ oftenHere: Bool) {
        Task {
            if await model.answerRecurringPlace(oftenHere, for: proposal), oftenHere { dismiss() }
        }
    }

    @ViewBuilder
    private var matchContent: some View {
        if let match {
            Group {
                Label {
                    Text(match.status.label).font(.headline)
                } icon: {
                    // A possible match gets a new album too: no check mark that reads as "done".
                    Image(systemName: [.newAlbumRequired, .possibleMatch].contains(match.status) ? "plus.rectangle.on.folder" : "checkmark.circle.fill")
                        .foregroundStyle(match.status.tint)
                }
                ForEach(Array(shownReasons(match).enumerated()), id: \.offset) { _, reason in
                    Text(ReasonText.text(reason)).font(.subheadline).foregroundStyle(.secondary)
                }
                if let choice = chosenAlbumText {
                    Label(choice, systemImage: "hand.point.up.left")
                        .font(.subheadline.weight(.semibold))
                }
                // "Passt nicht" names one album; with several albums the choice happens under "Album auswählen".
                if let best = match.best, best.isEditable, ![.newAlbumRequired, .multipleMatches].contains(match.status) {
                    // A possible match already gets a new album: the button only stops offering it.
                    let onlyOffered = match.status == .possibleMatch
                    Button { rejectingMatch = true } label: {
                        Group {
                            if onlyOffered {
                                Text("„\(best.albumTitle)“ nicht mehr anbieten")
                            } else {
                                Text("„\(best.albumTitle)“ passt nicht")
                            }
                        }
                            .font(.subheadline.weight(.semibold))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                        .disabled(preparing)
                        .confirmationDialog("Dieses Album passt nicht?", isPresented: $rejectingMatch, titleVisibility: .visible) {
                            Button("Nicht mehr für diesen Vorschlag anbieten") {
                                Task { await model.rejectMatch(best.albumID, for: proposal) }
                            }
                        } message: {
                            if onlyOffered {
                                Text("Albumist legt ohnehin ein neues Album an und bietet dieses unter „Anpassen“ nicht mehr an. Am Album selbst ändert sich nichts.")
                            } else {
                                Text("Albumist merkt sich das und schlägt stattdessen ein neues oder ein anderes passendes Album vor. Am Album selbst ändert sich nichts.")
                            }
                        }
                }
            }
        }
    }

    /// Several albums fit (or none clearly): the user picks one, Albumist does not guess.
    private var needsChoice: Bool {
        if case .undecided = recommended { return !proposal.requiresUserName }
        return false
    }

    /// "Albumist legt ein neues Album an" is not true any more once the user picked the
    /// album under "Anpassen"; "Deine Wahl" says what happens instead.
    private func shownReasons(_ match: MatchResult) -> [MatchReason] {
        guard case .extendExisting = model.decision(for: proposal) else { return match.reasons }
        return match.reasons.filter { if case .keptUnchangedUntilChosen = $0 { false } else { true } }
    }

    /// The user's pick from "Anpassen", shown where Albumist could not decide alone (several
    /// albums, none clearly, or only a possible match).
    private var chosenAlbumText: String? {
        guard let match, [.multipleMatches, .ambiguous, .possibleMatch].contains(match.status) else { return nil }
        switch model.decision(for: proposal) {
        case .extendExisting(let id):
            let title = model.inventory[id]?.title ?? ""
            return String(localized: "Deine Wahl: „\(title)“ ergänzen")
        case .createNew:
            return String(localized: "Deine Wahl: neues Album")
        default:
            return nil
        }
    }

    private var actions: some View {
        VStack(spacing: Theme.Spacing.s) {
            Button {
                if needsChoice {
                    showAdjust = true
                } else {
                    Task { await applyNow() }
                }
            } label: {
                if preparing {
                    ProgressView().frame(maxWidth: .infinity)
                        .accessibilityLabel(Text("Wird vorbereitet"))
                } else {
                    Text(primaryTitle)
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled((!recommended.isAccepted && !needsChoice) || preparing)

            HStack(spacing: Theme.Spacing.s) {
                Button("Anpassen") { showAdjust = true }.buttonStyle(SecondaryButtonStyle())
                    .disabled(preparing)
                Button("Nicht jetzt") {
                    model.setDecision(.reject, for: proposal)
                    dismiss()
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            if recommended.isAccepted && !recommended.isKeepExisting {
                Button { accept(); dismiss() } label: {
                    Text("Auswählen und später anlegen")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
            }
        }
        .padding(.top, Theme.Spacing.s)
    }

    /// The preview of "Album anlegen" is on the stack.
    private var showsDirect: Bool {
        guard let directPlan, let navigator else { return false }
        return navigator.path.contains(.prebuiltPlan(directPlan))
    }

    private func accept() {
        if proposal.requiresUserName { model.setUserTitle(name, for: proposal) }
        model.setDecision(recommended, for: proposal)
    }

    /// Applies this one suggestion right away (preview, then the album exists in Photos).
    private func applyNow(attempt: Int = 1) async {
        waiting = nil
        if proposal.requiresUserName { model.setUserTitle(name, for: proposal) }
        let chosen = recommended
        let previous = model.decisions[proposal.id]
        previewSelection = model.selectForPreview([(proposal, chosen)])
        let basis = planBasis
        let request = PlanRequest(model: model, navigator: navigator)
        preparing = true
        let plan = await model.singlePlan(for: proposal)
        preparing = false
        guard let plan else {
            // Nothing to change (album already complete or kept as it is): the pick goes back,
            // and the suggestion closes if it still shows.
            endSelection()
            if navigator?.isShowing(request.mark) == true { dismiss() }
            return
        }
        offer(WaitingPlan(token: PlanToken(plan), request: request, chosen: chosen, previous: previous, basis: basis), attempt: attempt)
    }

    /// A preview of "Album anlegen" that is ready, or that waited for this tab, with the same
    /// checks both times (`PlanRequest`, `PlanBasis`): shown with its pick (made again after a
    /// wait); kept without the pick while another tab is chosen; made again once when the album
    /// list or the suggestion changed meanwhile (a second change says Albumist is busy);
    /// dropped when the user went elsewhere on this stack or chose otherwise for the suggestion.
    /// Whenever it is not shown, its pick goes back at once. Never pushed twice: `waiting`
    /// holds it only while it is not shown.
    private func offer(_ ready: WaitingPlan, attempt: Int) {
        var verdict = ready.request.verdict(model: model, navigator: navigator)
        if verdict == .show || verdict == .stale {
            // While the pick is on, the decision is the pick; while the plan waits, the one before.
            let expected = previewSelection == nil ? ready.previous : ready.chosen
            if model.decisions[proposal.id] != expected {
                verdict = .gone
            } else if planBasis != ready.basis {
                verdict = .stale
            }
        }
        if verdict == .show {
            if previewSelection == nil { previewSelection = model.selectForPreview([(proposal, ready.chosen)]) }
            if Navigator.push(.prebuiltPlan(ready.token), on: navigator, ifStill: ready.request.mark) == .pushed {
                directPlan = ready.token
                return
            }
            verdict = .gone
        }
        endSelection()
        switch verdict {
        case .wait:
            waiting = ready
        case .busy:
            model.message = .busy
        case .stale:
            if attempt > 1 {
                model.message = .busy
            } else if planBasis.proposal != nil {
                // The spinner stays on until the new plan is made.
                preparing = true
                Task { await applyNow(attempt: attempt + 1) }
            }
            // Otherwise the analysis no longer has this suggestion: nothing is made from it.
        case .show, .gone:
            break
        }
    }

    /// The tab shows again: a preview that was ready meanwhile is offered now.
    private func showWaiting() {
        guard let ready = waiting, navigator?.showing == true else { return }
        waiting = nil
        offer(ready, attempt: 1)
    }

    /// The preview's pick goes back (`AppModel.endPreview`).
    private func endSelection() {
        if let selection = previewSelection { model.endPreview(selection) }
        previewSelection = nil
    }

    /// A preview of "Album anlegen" kept for this screen (`waiting`).
    private struct WaitingPlan {
        let token: PlanToken
        let request: PlanRequest
        /// The decision the preview selects, and the one it replaced.
        let chosen: ProposalDecision
        let previous: ProposalDecision?
        let basis: PlanBasis
    }

    /// What a plan of this suggestion is made from besides the album list (`PlanRequest`), as
    /// far as the app can see it changing: the suggestion as the analysis has it now, the photos
    /// taken out of it, its name and the folder for new albums.
    private struct PlanBasis: Equatable {
        let proposal: AlbumProposal?
        let removed: Set<AssetID>?
        let title: String?
        let rootFolder: String
    }

    private var planBasis: PlanBasis {
        PlanBasis(proposal: model.proposals.first { $0.id == proposal.id },
                  removed: model.removedFromProposals[proposal.id],
                  title: model.userTitles[proposal.id],
                  rootFolder: model.settings.rootFolderTitle)
    }

    /// Photos still missing in the album the user chose (not necessarily Albumist's first candidate).
    private func missingPhotos(in albumID: CollectionID) -> Int? {
        guard let match else { return nil }
        let candidate = ([match.best].compactMap { $0 } + match.alternatives).first { $0.albumID == albumID }
        return candidate.map { proposal.assetIDs.count - $0.metrics.intersection }
    }

    private var primaryTitle: LocalizedStringKey {
        switch recommended {
        case .keepExisting: "Album so lassen"
        case .extendExisting(let id):
            if let missing = missingPhotos(in: id), missing > 0 {
                "\(missing) Fotos ergänzen"
            } else {
                "Album ergänzen"
            }
        case .createNew: "Album anlegen"
        case .undecided: proposal.requiresUserName ? "Erst einen Namen eingeben" : "Album auswählen"
        default: "Auswählen"
        }
    }
}

/// Choose between creating a new album and using one of the matching albums.
struct AdjustProposalView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var proposal: AlbumProposal
    @State private var title = ""

    private var candidates: [MatchCandidate] {
        guard let match = model.match(for: proposal) else { return [] }
        return ([match.best].compactMap { $0 } + match.alternatives).filter(\.isEditable)
    }

    var body: some View {
        Form {
            // Choosing only selects; nothing is created here (design review W3).
            Section {
                TextField("Titel", text: $title)
                Button("Neues Album wählen") {
                    let trimmed = title.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { model.setUserTitle(trimmed, for: proposal) }
                    model.setDecision(.createNew(title: trimmed.isEmpty ? nil : trimmed, folderPath: nil), for: proposal)
                    dismiss()
                }
                .disabled(proposal.requiresUserName && title.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Neues Album")
            } footer: {
                Text("Angelegt wird erst, wenn du in der Vorschau bestätigst.")
            }
            Section {
                ForEach(candidates, id: \.albumID) { candidate in
                    Button {
                        model.setDecision(.extendExisting(candidate.albumID), for: proposal)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(candidate.albumTitle)
                            Text("\(candidate.metrics.intersection) gemeinsame Fotos").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
                NavigationLink("Anderes Album wählen") {
                    AlbumPickerView(excluded: Set(candidates.map(\.albumID))) { id in
                        model.setDecision(.extendExisting(id), for: proposal)
                        dismiss()
                    }
                }
            } header: {
                Text("Vorhandenes Album ergänzen")
            }
        }
        .navigationTitle("Anpassen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
        }
        .onAppear { title = model.userTitles[proposal.id] ?? (proposal.requiresUserName ? "" : proposal.title) }
    }
}

/// Every album Albumist may change, searchable; used when no suggested album fits.
struct AlbumPickerView: View {
    @Environment(AppModel.self) private var model
    var excluded: Set<CollectionID> = []
    var onPick: (CollectionID) -> Void
    @State private var query = ""

    private var albums: [CollectionSnapshot] {
        let all = model.inventory.albums.filter { $0.isEditableAlbum && !excluded.contains($0.id) }
        let filtered = query.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(query) }
        return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        List {
            // The system's empty search state (design review N12).
            if albums.isEmpty && !query.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if albums.isEmpty {
                Text("Noch keine Alben").foregroundStyle(.secondary)
            }
            ForEach(albums) { album in
                Button {
                    onPick(album.id)
                } label: {
                    HStack {
                        Label(album.title, systemImage: "rectangle.stack")
                        Spacer()
                        Text(album.assetIDs.count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .foregroundStyle(.primary)
            }
        }
        .searchable(text: $query, prompt: Text("Album suchen"))
        .navigationTitle("Album wählen")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Every photo of one suggestion, oldest first. Photos that do not belong can be taken out of
/// this suggestion; they stay in the library and in other suggestions.
struct ProposalPhotosView: View {
    @Environment(AppModel.self) private var model
    var proposal: AlbumProposal
    @State private var selecting = false
    @State private var selected: Set<AssetID> = []
    @State private var confirmRemove = false
    @State private var viewing: PhotoViewer.Start?
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 3)]

    var body: some View {
        let members = model.members(of: proposal)
        ScrollView {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(members, id: \.self) { id in
                    tile(id)
                }
            }
        }
        .navigationTitle(Text("\(members.count) Fotos"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(selecting ? "Fertig" : "Auswählen") {
                    withAnimation(.snappy) {
                        selecting.toggle()
                        selected = []
                    }
                }
            }
            if selecting {
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive) {
                        confirmRemove = true
                    } label: {
                        Text("\(selected.count) aus Vorschlag entfernen")
                    }
                    .disabled(selected.isEmpty)
                }
            }
        }
        .confirmationDialog("Fotos aus diesem Vorschlag entfernen?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Entfernen", role: .destructive) {
                let chosen = selected
                Task {
                    await model.removeFromProposal(chosen, proposal: proposal)
                    withAnimation(.snappy) {
                        selected = []
                        selecting = false
                    }
                }
            }
        } message: {
            Text("Sie kommen nicht in dieses Album. In deiner Mediathek und in anderen Vorschlägen bleiben sie.")
        }
        .fullScreenCover(item: $viewing) { start in
            PhotoViewer(ids: start.ids, current: start.id, showsInfo: true)
        }
    }

    /// A real button with the photo's date as its name, like the library grid (design review
    /// D3: the tile had only a tap gesture and no name, so VoiceOver and Voice Control could
    /// not pick photos to take out of the suggestion).
    private func tile(_ id: AssetID) -> some View {
        let isSelected = selected.contains(id)
        return Button {
            // Outside "Auswählen" a tap opens the photo large (first device test 15.11.).
            guard selecting else {
                // A snapshot: a photo ignored from its details must not reshuffle the pages.
                viewing = PhotoViewer.Start(id: id, ids: model.members(of: proposal))
                return
            }
            if isSelected { selected.remove(id) } else { selected.insert(id) }
        } label: {
            AssetThumbnail(id: id, side: 120)
                .aspectRatio(1, contentMode: .fill)
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if selecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, isSelected ? Theme.accent : Color.black.opacity(0.25))
                            .padding(5)
                            .accessibilityHidden(true)
                    }
                }
                .opacity(selecting && !isSelected ? 0.85 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(model.creationDates[id]?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "Foto")))
        .accessibilityAddTraits(selecting && isSelected ? .isSelected : [])
        .accessibilityIdentifier("proposalPhotos.photo")
    }
}

/// Symbol and text close together, like a status line (the list's own label style
/// puts the symbol in a wide icon column).
private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}
