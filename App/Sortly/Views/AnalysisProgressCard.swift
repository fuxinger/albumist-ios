import SwiftUI
import SortlyCore
import SortlyEngine

/// The analysis on the overview (progress display v3, `progress-display/ENTWURF.md`): one bar
/// in six segments for the whole analysis, the step's count, the finish time, what is already
/// done, and every waiting state in words. The state comes from `AppModel.analysisCard`
/// (pure rules in `AnalysisCardState`, tested in SortlyEngine); this view only renders it.
///
/// At a glance only that (review of 18.11., P3-08: nine things at once were too many for a
/// newcomer and for a hurried user): the heading with its one button, the count, one short
/// line, the bar, "Schon fertig" and "Details". The step it stands on, the photos just looked
/// at, whether it runs in the background and the note on town names are in "Details"
/// (`AnalysisDetailsSheet`); VoiceOver still says the step (`AnalysisCardGlanceTests`). Only
/// when iOS refused the background time does the short line say "Läuft, solange Albumist offen
/// ist", in place of the finish time (`runsOnlyWhileOpen`).
struct AnalysisProgressCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var showDetails = false
    /// What VoiceOver and other assistive tools read from the progress element, renewed at
    /// most once a second (`renewSpoken`). The visible count and bar keep moving with every
    /// tick (4 per second); an accessibility tree that changed with them made every read of
    /// the screen during the analysis slow (UI run 43979263666: 16 to 48 s on the simulator).
    @State private var spokenValue = ""
    @State private var spokenOverall = 0.0
    @State private var spokenAt = Date.distantPast
    @State private var spokenPending: Task<Void, Never>?
    /// The newest value, kept without redrawing; the delayed renewal takes it from here (the
    /// view it was started from holds the card state of that moment).
    @State private var newest = NewestSpoken()
    var state: AnalysisCardState
    /// "Analyse fertig" was tapped: the page shows the sheet "Analyse".
    var onOpenFinished: () -> Void = {}

    var body: some View {
        // On the ring card of "Vorschläge" (design wave 1): each part brings the card's margins.
        Group {
            switch state {
            case .quickCheck(let showsPause):
                quickCheck(showsPause: showsPause)
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.vertical, Theme.Spacing.s)
            case .finished(let photos, let proposals):
                AnalysisFinishedView(photos: photos, proposals: proposals, onOpen: onOpenFinished)
            default:
                full
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.vertical, Theme.Spacing.m)
            }
        }
        // B2: said when the step changes, on Pause, waiting and the end; quietly (low priority,
        // so it does not cut into what VoiceOver is reading), and only while on screen.
        .onChange(of: announcement) { _, text in
            guard let text, scenePhase == .active else { return }
            var spoken = AttributedString(text)
            spoken.accessibilitySpeechAnnouncementPriority = .low
            AccessibilityNotification.Announcement(spoken).post()
        }
        .sheet(isPresented: $showDetails) { AnalysisDetailsSheet() }
    }

    // MARK: Parts

    private var position: AnalysisCardState.Position? {
        switch state {
        case .running(let p, _, _, _), .waiting(_, let p), .pausing(let p, _), .paused(let p): p
        default: nil
        }
    }

    private var title: String {
        switch state {
        case .running(let p, _, _, let catchingUp):
            // A phase of its own after a stop, or many new photos seen by the library read:
            // why the number starts again or is held longer (reviews of 83db832 and 11ef3e1).
            if let newWork = model.analysis.newWork { return AnalysisText.newWork(newWork) }
            if catchingUp != nil { return String(localized: "Macht da weiter, wo sie aufgehört hat") }
            return p?.step.labelText ?? String(localized: "Analyse läuft")
        case .waiting(.cooling, _): return String(localized: "Wartet, bis dein iPhone abkühlt")
        case .waiting(.charging, _): return String(localized: "Wartet aufs Laden")
        case .waiting(.photos, _): return String(localized: "Fotos antwortet gerade nicht")
        case .waiting(.busy, _): return String(localized: "Albumist war gerade ausgelastet")
        case .pausing: return String(localized: "Wird angehalten …")
        case .paused: return String(localized: "Analyse pausiert")
        case .quickCheck: return String(localized: "Sucht neue Fotos")
        case .finished: return String(localized: "Analyse fertig")
        }
    }

    /// What VoiceOver announces when it changes (nil: nothing to say).
    private var announcement: String? {
        switch state {
        case .running(let p, _, _, let catchingUp) where catchingUp == nil: p.map { $0.step.labelText }
        case .running: nil
        case .quickCheck: nil
        default: title
        }
    }

    private var headingSymbol: String? {
        switch state {
        case .waiting(.cooling, _): "thermometer.medium"
        case .waiting(.charging, _): "battery.25percent"
        case .waiting(.photos, _), .waiting(.busy, _): "hourglass"
        case .paused: "pause.circle"
        default: nil
        }
    }

    /// What the card shows at a glance (P3-08): the heading with its one button, the progress
    /// (count, one short line, bar), "Schon fertig" and "Details". Nothing more: what moved to
    /// "Details" stays there, and adding a part here means another one goes.
    private var full: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            header
            progress
            alreadyDone
            if !isPaused { Divider() }
            Button { showDetails = true } label: {
                HStack {
                    Text("Details").foregroundStyle(Color.primary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("analysis.details")
        }
        // B1: the card is a container; inside it one element for the progress and own buttons.
        .accessibilityElement(children: .contain)
    }

    /// Heading and Pause (or Fortsetzen); the button moves under the heading when the text is
    /// large or long (B5). Pause is the round button of draft B (E6), centred beside the heading.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center) {
                heading
                Spacer(minLength: Theme.Spacing.s)
                control
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                heading
                control
            }
        }
    }

    private var heading: some View {
        HStack(spacing: Theme.Spacing.s) {
            if case .pausing = state {
                ProgressView().controlSize(.small)
                    .accessibilityHidden(true) // the text beside it says what runs
            } else if let headingSymbol {
                Image(systemName: headingSymbol).foregroundStyle(.secondary)
            }
            Text(title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Read out as part of the progress element below (B1).
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var control: some View {
        switch state {
        case .paused:
            Button { model.startAnalysis(cause: .tap) } label: { CardTextButton("Fortsetzen") }
                .accessibilityLabel("Analyse fortsetzen")
                .accessibilityIdentifier("analysis.resume")
        case .pausing:
            EmptyView()
        case .waiting(.photos, _) where !model.analysis.isRunning, .waiting(.busy, _) where !model.analysis.isRunning:
            // The run ended because Photos did not answer, or because Albumist was too busy to
            // ask it; the next try comes by itself, or now.
            Button { model.startAnalysis(cause: .tap) } label: { CardTextButton("Jetzt versuchen") }
                .accessibilityLabel("Analyse jetzt erneut versuchen")
                .accessibilityIdentifier("analysis.retry")
        default:
            Button { model.pauseAnalysis() } label: { PauseSymbol() }
                .buttonStyle(.plain)
                .accessibilityLabel("Pause")
                .accessibilityIdentifier("analysis.pause")
        }
    }

    /// Count, the short line and the bar: ONE accessibility element shown as a progress view
    /// (B1). The step ("Schritt 4 von 6") is in its value and in "Details", no longer under the
    /// bar (P3-08): the heading names the step, the bar shows how far the whole analysis is.
    private var progress: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if let position, position.hasCount, !isWaitingOrPaused {
                count(position)
            }
            statusLines
            AnalysisBar(widths: model.analysis.widths, grey: state.isGrey, working: state.isWorking,
                        runningStep: position?.step)
        }
        .accessibilityRepresentation {
            ProgressView(value: spokenOverall) { Text(title) }
        }
        .accessibilityLabel(title)
        .accessibilityValue(spokenValue)
        // Only while something runs: a paused or waiting card does not change by itself.
        .accessibilityAddTraits(isRunning ? .updatesFrequently : [])
        .accessibilityIdentifier("analysis.progress")
        .onChange(of: accessibilityValue, initial: true) { renewSpoken() }
        // UI runs only: the line as XCTest reads it, with the app's time (`ProgressLineLog`).
        #if DEBUG
        .onChange(of: ProgressLineLog.isOn ? title + " " + spokenValue : "", initial: true) { _, line in
            if !line.isEmpty { ProgressLineLog.note(line) }
        }
        #endif
        // A new state or step is said at once, so the words and the spoken value agree.
        .onChange(of: state.phase) { renewSpoken(now: true) }
        .onChange(of: position?.step) { renewSpoken(now: true) }
        // onDisappear drops a queued update: on return the value is taken afresh.
        .onAppear {
            renewSpoken(now: true)
            #if DEBUG
            if ProgressLineLog.isOn { ProgressLineLog.note(title + " " + spokenValue) }
            #endif
        }
        .onDisappear {
            spokenPending?.cancel()
            spokenPending = nil
            #if DEBUG
            ProgressLineLog.note("-")
            #endif
        }
    }

    /// Takes the current value for assistive tools at once when a second has passed since the
    /// last one (or `now`: a change of state is said right away), otherwise once that second is
    /// over, with whatever the value is by then.
    private func renewSpoken(now: Bool = false) {
        newest.value = accessibilityValue
        newest.overall = model.analysis.shownOverall
        let wait = 1 - Date().timeIntervalSince(spokenAt)
        guard !now, wait > 0 else {
            spokenPending?.cancel()
            spokenPending = nil
            takeSpoken()
            return
        }
        guard spokenPending == nil else { return }
        spokenPending = Task { @MainActor in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            spokenPending = nil
            takeSpoken()
        }
    }

    private func takeSpoken() {
        spokenValue = newest.value
        spokenOverall = newest.overall
        spokenAt = Date()
    }

    private var isRunning: Bool { if case .running = state { true } else { false } }

    /// iOS refused the background time (S8): the analysis goes on only while Albumist is open,
    /// which matters before the user leaves it. Said in the finish time's place while it runs
    /// (the finish time stays in Details), not during Apple's countdown, which says why it
    /// waits. Every other word on the background stays in Details (decision of 20.11.: the
    /// card keeps five parts).
    private var runsOnlyWhileOpen: Bool {
        guard case .running(_, _, let appleWait, _) = state, !appleWait else { return false }
        return model.analysisBackground == .refused
    }

    private var isWaitingOrPaused: Bool {
        switch state {
        case .waiting, .paused, .pausing: true
        default: false
        }
    }

    /// "2.431" large, "von 5.683 Fotos" beside it (under it at the largest sizes). The digits
    /// roll only when the step changes, not with every count (S3).
    private func count(_ position: AnalysisCardState.Position) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
        return layout {
            Text(position.completed, format: .number)
                .font(.title.weight(.semibold))
                .contentTransition(.numericText(value: Double(position.completed)))
            Text(AnalysisText.ofTotal(position.total, position.step.unit))
                .font(.subheadline).foregroundStyle(.noteText)
        }
        .monospacedDigit()
        .animation(reduceMotion ? nil : .snappy, value: position.step)
    }

    /// Under the count: the finish time (or that it runs only while Albumist is open), the wait
    /// for Apple's limit, why it is slower, what waiting means.
    @ViewBuilder
    private var statusLines: some View {
        Group {
            switch state {
            case .running(_, let slower, let appleWait, _):
                if appleWait {
                    // Only the overnight refinement waits for Apple's geocoder (a run in the app
                    // never does), seen when the app is opened while it runs. It says why, with
                    // a countdown renewed every 2 s, in minutes above one (a wait after a refusal
                    // lasts up to 10 min); the spinner moves meanwhile (limit: nothing stands
                    // still for more than 10 s without saying why; device test 18.11., build 36).
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                            .accessibilityHidden(true)
                        Text(AnalysisText.appleWait(model.analysis.appleWaitLeft ?? .zero))
                            .contentTransition(.numericText(countsDown: true))
                            .accessibilityIdentifier("analysis.appleWait")
                    }
                } else if runsOnlyWhileOpen {
                    Text("Läuft, solange Albumist offen ist")
                        .accessibilityIdentifier("analysis.onlyWhileOpen")
                } else if let finish = model.analysisFinish {
                    Text(AnalysisText.finish(finish))
                        .accessibilityIdentifier("analysis.finishTime")
                }
                // The places step's pass over the map: towns only count after their lookup, so
                // this is what moves meanwhile (review of d612bc0: "0 von 50.233 Orten" for 60 s).
                if let pass = model.analysis.mapPass, pass.checked < pass.of {
                    Text(AnalysisText.mapChecked(pass))
                }
                if slower == .warm {
                    Text("Langsamer, weil dein iPhone warm ist")
                } else if slower == .lowPower {
                    Text("Langsamer, weil der Stromsparmodus an ist")
                }
            case .waiting(.cooling, _):
                Text("Geht von selbst weiter. Du musst nichts tun.")
            case .waiting(.charging, _):
                Text("Unter \(Int(DeviceState.appBatteryFloor * 100)) % Akku. Geht weiter, sobald dein iPhone lädt.")
            case .waiting(.photos, _):
                Text("Albumist wartet auf die Fotos-App und versucht es sonst gleich noch einmal. Du musst nichts tun.")
            case .waiting(.busy, _):
                Text("Geht gleich von selbst weiter. Du musst nichts tun.")
            case .pausing(_, let longer):
                Text("Macht noch fertig, was gerade läuft.")
                if longer { Text("Dauert noch einen Moment.") }
            case .paused(let p):
                if let p, p.hasCount {
                    Text("Bei \(AnalysisText.count(p)). Sie macht genau dort weiter.")
                } else {
                    Text("Die Analyse setzt genau dort fort, wo sie aufgehört hat.")
                }
            default:
                EmptyView()
            }
        }
        .font(.subheadline).foregroundStyle(.noteText).monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The step in the VoiceOver value ("Schritt 4 von 6", the UI tests read it there), with the
    /// count while it waits or stops, when the large number is not shown.
    private var stepLine: String {
        let step = state.stepText ?? String(localized: "Schritt \(1) von \(AnalysisStep.count)")
        if case .running(_, _, _, _?) = state { return step }
        if isWaitingOrPaused, let position, position.hasCount, !isPaused {
            return step + " · " + AnalysisText.count(position)
        }
        return step
    }

    private var isPaused: Bool { if case .paused = state { true } else { false } }

    /// B1: "2.431 von 5.683 Fotos, fertig gegen 23:40, Schritt 4 von 6".
    private var accessibilityValue: String {
        var parts: [String] = []
        if let position, position.hasCount { parts.append(AnalysisText.count(position)) }
        if case .running = state, let pass = model.analysis.mapPass, pass.checked < pass.of {
            parts.append(AnalysisText.mapChecked(pass))
        }
        if runsOnlyWhileOpen {
            parts.append(String(localized: "Läuft, solange Albumist offen ist"))
        } else if case .running = state, let finish = model.analysisFinish {
            parts.append(AnalysisText.finish(finish))
        }
        parts.append(stepLine)
        parts.append(String(localized: "Analyse zu \(AnalysisPercent.percent(model.analysis.shownOverall, isComplete: model.analysis.isComplete)) % fertig"))
        return parts.joined(separator: ", ")
    }

    /// "Schon fertig: 51 Reisen, 38 Orte" with "Ansehen" (point 3), while the analysis goes on.
    @ViewBuilder
    private var alreadyDone: some View {
        let done = AlreadyDone.counts(proposals: model.proposals, step: position?.step)
        if !done.isEmpty, !isPaused {
            let row = HStack(spacing: Theme.Spacing.s) {
                Text("Schon fertig: \(Text(AnalysisText.alreadyDone(done)).foregroundStyle(Color.primary))")
                    .font(.subheadline).foregroundStyle(.noteText).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                // Opened from the overview's root (`MainTabs`, route `.proposals`): this row goes
                // away when the step changes or the analysis pauses, and a link in it took its
                // open list along (the overview's own links did, UI run 44038288087).
                Button { model.route = .proposals } label: {
                    CardTextButton("Ansehen")
                }
                .accessibilityIdentifier("analysis.showDone")
            }
            row
                .padding(.leading, Theme.Spacing.m)
                .padding(.trailing, Theme.Spacing.xs)
                .padding(.vertical, 2)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    /// The short check for new photos: one line with a spinner; Pause only after 5 s (rule 9).
    private func quickCheck(showsPause: Bool) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            ProgressView().controlSize(.small)
                .accessibilityHidden(true) // the text beside it says what runs
            Text("Sucht neue Fotos").font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Theme.Spacing.s)
            if showsPause {
                Button { model.pauseAnalysis() } label: { PauseSymbol() }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Pause")
                    .accessibilityIdentifier("analysis.pause")
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Bar

/// Six segments, each as wide as its step's share of the time (fixed for the analysis), with
/// small gaps; the value comes from `AppModel.analysisBar`. Read only here, so the bar's four
/// changes a second redraw this view and nothing else on the overview (S2).
///
/// Gliding (point 2) is computed on the model's 250 ms tick (`BarGlide`), and each new value is
/// animated linearly over those 250 ms. Chosen over a `TimelineView(.animation)` on the running
/// segment: the tick runs anyway for the throttled progress, so this adds four body updates a
/// second of this small view and one animatable shape, where the timeline would evaluate a body
/// 15 times a second while Vision runs on four lanes (S1). The animation only interpolates
/// `SegmentFill.fraction` (a path), not a view body.
struct AnalysisBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var height: CGFloat = 8
    var widths: StepWidths
    var grey: Bool
    var working: Bool
    var runningStep: AnalysisStep?

    var body: some View {
        let fills = widths.fills(for: model.analysisBar)
        SegmentRow(shares: widths.shares) {
            ForEach(AnalysisStep.allCases, id: \.self) { step in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(uiColor: .systemFill))
                        .overlay(Capsule().strokeBorder(Color(uiColor: .separator), lineWidth: 0.5))
                    SegmentFill(fraction: fills[step.rawValue])
                        .fill(grey ? Color.secondary : Theme.accent)
                    if working, step == runningStep {
                        LightSweep()
                            .mask { SegmentFill(fraction: fills[step.rawValue]) }
                    }
                }
            }
        }
        .frame(height: min(height, 14))
        .animation(reduceMotion ? nil : .linear(duration: 0.25), value: model.analysisBar)
        .accessibilityHidden(true)
    }
}

/// Places six views side by side with the given shares of the width and 3 pt gaps.
struct SegmentRow: Layout {
    var shares: [Double]
    var gap: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 200, height: 8))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let usable = max(0, bounds.width - gap * CGFloat(max(0, subviews.count - 1)))
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            let share = index < shares.count ? shares[index] : 0
            let width = usable * CGFloat(share)
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + gap
        }
    }
}

/// The filled part of a segment: a capsule as wide as `fraction` of it. Animatable, so a
/// change is drawn as a path per frame, not as a view update.
struct SegmentFill: Shape {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let width = rect.width * CGFloat(min(1, max(0, fraction)))
        guard width > 0 else { return Path() }
        let filled = CGRect(x: rect.minX, y: rect.minY, width: max(width, min(rect.height, rect.width)), height: rect.height)
        return Path(roundedRect: filled, cornerRadius: rect.height / 2)
    }
}

/// A soft light band through the running segment (rule 4): started once with a repeating
/// animation on an offset (no view body per frame, S1). Off while waiting or paused (not shown),
/// with Reduce Motion, when the app is not active, and from `.serious` heat on.
struct LightSweep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var moving = false

    var body: some View {
        GeometryReader { geometry in
            if !reduceMotion, scenePhase == .active, ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue {
                LinearGradient(colors: [.white.opacity(0), .white.opacity(0.45), .white.opacity(0)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: max(24, geometry.size.width * 0.45))
                    .offset(x: moving ? geometry.size.width * 1.2 : -geometry.size.width * 0.6)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: false)) { moving = true }
                    }
                    .onDisappear { moving = false }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Pause as draft B draws it (E6 "Analyse läuft"): the system's pause symbol on a round grey
/// fill, 44 pt and growing with the text; VoiceOver says "Pause" (the button's label).
private struct PauseSymbol: View {
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 44

    var body: some View {
        let side = min(self.side, 88)
        Image(systemName: "pause.fill")
            .font(.body.weight(.semibold))
            .foregroundStyle(Color.primary)
            .frame(width: side, height: side)
            .background(Color(uiColor: .tertiarySystemFill), in: Circle())
            .contentShape(Circle())
            .hoverEffect(.highlight)
            .accessibilityHidden(true)
    }
}

/// A short text action in the card with Apple's minimum tap area (44 pt).
struct CardTextButton: View {
    var title: LocalizedStringKey
    init(_ title: LocalizedStringKey) { self.title = title }

    var body: some View {
        Text(title)
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

// MARK: - Finished

/// Point 4: a long run finished while the card was on screen. A short check mark and a light
/// haptic once (not on every return to the overview, not with Reduce Motion: then only the
/// crossfade of the card). One line of the ring card (draft B): the suggestions wait right
/// under it on the page, so no button of its own; the line opens the sheet "Analyse", with
/// how many photos are analysed.
struct AnalysisFinishedView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = 0
    var photos: Int
    var proposals: Int
    var onOpen: () -> Void = {}

    var body: some View {
        Button(action: onOpen) {
            RingCardRow(title: Text("Analyse fertig"), chevron: true) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.bounce, value: bounce)
                    .accessibilityHidden(true)
            } detail: {
                Text(String(localized: "\(proposals) Vorschläge warten auf dich."))
                    .monospacedDigit()
            }
        }
        .buttonStyle(RingCardRowButtonStyle())
        .sensoryFeedback(.success, trigger: bounce) { _, new in new > 0 && !reduceMotion }
        .onAppear(perform: play)
        // Finished while the app was in the background: played when it is on screen again.
        .onChange(of: model.isOnScreen) { _, onScreen in if onScreen { play() } }
        .accessibilityIdentifier("analysis.finished")
    }

    private func play() {
        guard model.claimFinishMoment(), !reduceMotion else { return }
        bounce += 1
    }
}

// MARK: - Details

/// "Details": all six steps with one sentence each and where they stand (rule 8). Also what the
/// card leaves out so it can be read at a glance (P3-08): the step on top ("Schritt 4 von 6"),
/// whether the analysis goes on in the background, the photos just looked at (in the image
/// step's row, B4) and the note on town names (in the places step's row).
struct AnalysisDetailsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationRoot {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        Text(summary(now: context.date))
                            .font(.subheadline).foregroundStyle(.noteText).monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityIdentifier("analysis.details.summary")
                    // Whether it goes on when Albumist is left (S8), and honestly: iOS gives work
                    // in the background less computing power (P4-13).
                    if let background {
                        Label(background.text, systemImage: background.symbol)
                            .font(.subheadline).foregroundStyle(.noteText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("analysis.background")
                    }
                    VStack(spacing: 0) {
                        ForEach(AnalysisStep.allCases, id: \.self) { step in
                            row(step)
                            if step != .proposals { Divider() }
                        }
                    }
                    Label("Alles passiert auf deinem iPhone. Nur für Städtenamen fragt Albumist bei Apple nach.", systemImage: "lock")
                        .font(.footnote)
                        .foregroundStyle(.noteText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(Theme.Spacing.m)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.top, Theme.Spacing.m)
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.bottom, Theme.Spacing.xl)
            }
            .navigationTitle("So läuft die Analyse")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// "Schritt 4 von 6 · Fertig gegen 23:40 · 46 % · bisher 18 Min."
    private func summary(now: Date) -> String {
        var parts: [String] = []
        // The step the card no longer shows under its bar (P3-08).
        if let step = model.analysisCard?.stepText { parts.append(step) }
        if let finish = model.analysisFinish, model.analysis.isRunning { parts.append(AnalysisText.finish(finish)) }
        // Never 100 % before the end (`AnalysisPercent`).
        parts.append(AnalysisPercent.value(model.analysisBar, isComplete: model.analysis.isComplete)
            .formatted(.percent.precision(.fractionLength(0))))
        if let start = model.analysisStartedAt, model.analysis.isRunning, !model.analysis.refining {
            let elapsed = Duration.seconds(max(60, now.timeIntervalSince(start)))
            parts.append(String(localized: "bisher \(elapsed.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))"))
        }
        return parts.joined(separator: " · ")
    }

    /// "Läuft im Hintergrund weiter, dort aber langsamer" while iOS lets the analysis go on when
    /// Albumist is left, "Läuft, solange Albumist offen ist" after iOS refused (S8); nothing while
    /// it is paused or nothing runs.
    private var background: (text: LocalizedStringKey, symbol: String)? {
        guard !isPaused else { return nil }
        switch model.analysisBackground {
        case .running: return ("Läuft im Hintergrund weiter, dort aber langsamer", "arrow.triangle.2.circlepath")
        case .refused: return ("Läuft, solange Albumist offen ist", "iphone")
        case .idle: return nil
        }
    }

    private var isPaused: Bool { if case .paused? = model.analysisCard { true } else { false } }

    /// The places step runs in the app (not during the overnight refinement: that is the
    /// "later" the note on town names speaks of, and it says itself what it waits for).
    private var placesRunInTheApp: Bool {
        guard case .running(let p, _, _, _)? = model.analysisCard else { return false }
        return p?.step == .places && !model.analysis.refining
    }

    private enum Standing { case done, running, later }

    private func standing(_ step: AnalysisStep) -> Standing {
        // After a complete run every row is done, also with the position where a foreground
        // run stood before (review of 0305d20, 5).
        if model.analysis.isComplete { return .done }
        guard let current = model.analysis.step ?? model.analysis.stoppedAt?.step else {
            return model.analysis.isComplete ? .done : .later
        }
        if step < current { return .done }
        return step == current ? .running : .later
    }

    private func row(_ step: AnalysisStep) -> some View {
        let standing = standing(step)
        let fraction = model.analysis.widths.fills(for: model.analysisBar)[step.rawValue]
        return HStack(alignment: .top, spacing: 14) {
            Group {
                switch standing {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                case .running:
                    ZStack {
                        Circle().stroke(Color(uiColor: .systemFill), lineWidth: 3)
                        Circle().trim(from: 0, to: max(0.02, fraction))
                            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .padding(2)
                case .later:
                    Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .font(.title3)
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        name(step, standing)
                        Spacer()
                        status(step, standing)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        name(step, standing)
                        status(step, standing)
                    }
                }
                Text(step.explanation)
                    .font(.footnote).foregroundStyle(.noteText)
                    .fixedSize(horizontal: false, vertical: true)
                if standing == .running, model.analysis.isRunning, let left = model.analysisStepRemaining {
                    Text("noch etwa \(AnalysisText.left(left))")
                        .font(.footnote).foregroundStyle(.noteText).monospacedDigit()
                        .accessibilityLabel(Text("noch etwa \(AnalysisText.left(left, width: .wide))"))
                }
                if step == .places, standing == .running, placesRunInTheApp {
                    Text("Städtenamen kommen von Apple, das braucht etwas Zeit. Was jetzt nicht fertig wird, holt Albumist nach, wenn dein iPhone das nächste Mal lädt.")
                        .font(.footnote).foregroundStyle(.noteText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                recentPhotos(step)
            }
        }
        .padding(.vertical, Theme.Spacing.m)
        .accessibilityElement(children: .combine)
    }

    /// "Gerade angesehen": the last photos the image step looked at, beside that step only, so
    /// never a screenshot (B4); none while paused. Only seen, not read out: the row says what runs.
    @ViewBuilder
    private func recentPhotos(_ step: AnalysisStep) -> some View {
        if step == .content, standing(step) == .running, !model.analysisRecent.isEmpty, !isPaused {
            HStack(spacing: Theme.Spacing.s) {
                HStack(spacing: 4) {
                    ForEach(model.analysisRecent, id: \.self) { id in
                        AssetThumbnail(id: id, side: 30)
                            .frame(width: 30, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
                Text("Gerade angesehen").font(.footnote).foregroundStyle(.noteText)
            }
            .padding(.top, Theme.Spacing.xs)
            .accessibilityHidden(true)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: model.analysisRecent)
        }
    }

    private func name(_ step: AnalysisStep, _ standing: Standing) -> some View {
        Text(step.listName)
            .font(standing == .running ? .body.weight(.semibold) : .body)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func status(_ step: AnalysisStep, _ standing: Standing) -> some View {
        switch standing {
        case .done:
            Text("fertig").font(.subheadline).foregroundStyle(.noteText)
        case .running:
            if let p = model.analysis.position ?? model.analysis.stoppedAt, p.hasCount {
                Text("\(p.completed.formatted()) von \(p.total.formatted())")
                    .font(.subheadline).monospacedDigit()
            }
        case .later:
            EmptyView()
        }
    }
}

extension AnalysisCardState {
    /// Which kind of state, without the counts: the card crossfades only when this changes.
    var phase: String {
        switch self {
        case .quickCheck: "check"
        case .running: "running"
        case .waiting(.cooling, _): "cooling"
        case .waiting(.charging, _): "charging"
        case .waiting(.photos, _): "photos"
        case .waiting(.busy, _): "busy"
        case .pausing: "pausing"
        case .paused: "paused"
        case .finished: "finished"
        }
    }

    /// "Schritt 4 von 6", or "Gleich wieder bei Schritt 4 von 6" while a run catches up after a
    /// stop; nil when no step runs. In "Details" and in the card's VoiceOver value (P3-08).
    var stepText: String? {
        let steps = AnalysisStep.count
        switch self {
        case .running(_, _, _, let catchingUp?):
            return String(localized: "Gleich wieder bei Schritt \(catchingUp) von \(steps)")
        case .running(let p, _, _, _), .waiting(_, let p), .pausing(let p, _), .paused(let p):
            return String(localized: "Schritt \(p?.step.number ?? 1) von \(steps)")
        case .quickCheck, .finished:
            return nil
        }
    }
}

/// See `AnalysisProgressCard.newest`.
@MainActor
private final class NewestSpoken {
    var value = ""
    var overall = 0.0
}
