import SwiftUI
import SortlyCore
import SortlyEngine

/// The analysis on the overview (progress display v3, `progress-display/ENTWURF.md`): one bar
/// in six segments for the whole analysis, the step's count, the finish time, what is already
/// done, and every waiting state in words. The state comes from `AppModel.analysisCard`
/// (pure rules in `AnalysisCardState`, tested in SortlyEngine); this view only renders it.
struct AnalysisProgressCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var showDetails = false
    var state: AnalysisCardState

    var body: some View {
        Group {
            switch state {
            case .quickCheck(let showsPause):
                quickCheck(showsPause: showsPause)
            case .finished(let photos, let proposals):
                AnalysisFinishedView(photos: photos, proposals: proposals)
            default:
                full
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
            if catchingUp != nil { return String(localized: "Macht da weiter, wo sie aufgehört hat") }
            return p?.step.labelText ?? String(localized: "Analyse läuft")
        case .waiting(.cooling, _): return String(localized: "Wartet, bis dein iPhone abkühlt")
        case .waiting(.charging, _): return String(localized: "Wartet aufs Laden")
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
        case .paused: "pause.circle"
        default: nil
        }
    }

    private var full: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            header
            progress
            if case .running(let p, _, _, _) = state, p?.step == .places {
                Text("Städtenamen kommen von Apple, das braucht etwas Zeit. Was jetzt nicht fertig wird, holt Albumist nach, wenn dein iPhone das nächste Mal lädt.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            alreadyDone
            if !isPaused { Divider() }
            bottomRow
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
    /// large or long (B5).
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
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
            Button { model.startAnalysis(userInitiated: true) } label: { CardTextButton("Fortsetzen") }
                .accessibilityLabel("Analyse fortsetzen")
                .accessibilityIdentifier("analysis.resume")
        case .pausing:
            EmptyView()
        default:
            Button { model.pauseAnalysis() } label: { CardTextButton("Pause") }
                .accessibilityIdentifier("analysis.pause")
        }
    }

    /// Count, status line, bar and step: ONE accessibility element shown as a progress view (B1).
    private var progress: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            if let position, position.hasCount, !isWaitingOrPaused {
                count(position)
            }
            statusLines
            AnalysisBar(widths: model.analysis.widths, grey: state.isGrey, working: state.isWorking,
                        runningStep: position?.step)
            Text(stepLine)
                .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
        }
        .accessibilityRepresentation {
            ProgressView(value: model.analysis.shownOverall) { Text(title) }
        }
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier("analysis.progress")
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
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .monospacedDigit()
        .animation(reduceMotion ? nil : .snappy, value: position.step)
    }

    /// Under the count: the finish time, Apple's wait, why it is slower, what waiting means.
    @ViewBuilder
    private var statusLines: some View {
        Group {
            switch state {
            case .running(_, let slower, let appleWait, _):
                if appleWait {
                    // The wait can last a minute; the spinner says it is alive meanwhile
                    // (limit: nothing stands still for more than 10 s while work goes on).
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                            .accessibilityHidden(true)
                        Text("Apple antwortet gleich")
                    }
                } else if let finish = model.analysisFinish {
                    Text(AnalysisText.finish(finish))
                        .accessibilityIdentifier("analysis.finishTime")
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
        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
        .fixedSize(horizontal: false, vertical: true)
    }

    private var stepLine: String {
        let steps = AnalysisStep.count
        if case .running(_, _, _, let catchingUp?) = state {
            return String(localized: "Gleich wieder bei Schritt \(catchingUp) von \(steps)")
        }
        guard let position else { return String(localized: "Schritt \(1) von \(steps)") }
        if isWaitingOrPaused, position.hasCount, !isPaused {
            return String(localized: "Schritt \(position.step.number) von \(steps)") + " · " + AnalysisText.count(position)
        }
        return String(localized: "Schritt \(position.step.number) von \(steps)")
    }

    private var isPaused: Bool { if case .paused = state { true } else { false } }

    /// B1: "2.431 von 5.683 Fotos, fertig gegen 23:40, Schritt 4 von 6".
    private var accessibilityValue: String {
        var parts: [String] = []
        if let position, position.hasCount { parts.append(AnalysisText.count(position)) }
        if case .running = state, let finish = model.analysisFinish { parts.append(AnalysisText.finish(finish)) }
        parts.append(stepLine)
        parts.append(String(localized: "Analyse zu \(Int((model.analysis.shownOverall * 100).rounded())) % fertig"))
        return parts.joined(separator: ", ")
    }

    /// "Schon fertig: 51 Reisen, 38 Orte" with "Ansehen" (point 3), while the analysis goes on.
    @ViewBuilder
    private var alreadyDone: some View {
        let done = AlreadyDone.counts(proposals: model.proposals, step: position?.step)
        if !done.isEmpty, !isPaused {
            let row = HStack(spacing: Theme.Spacing.s) {
                Text("Schon fertig: \(Text(AnalysisText.alreadyDone(done)).foregroundStyle(Color.primary))")
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                NavigationLink {
                    ProposalListView(area: nil)
                } label: {
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

    /// "Gerade angesehen" (image step only, B4) and the background chip (S8).
    @ViewBuilder
    private var bottomRow: some View {
        let showThumbnails = position?.step == .content && !model.analysisRecent.isEmpty && !isPaused
        let chip = chipText
        if showThumbnails || chip != nil {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.m) {
                    if showThumbnails { thumbnails }
                    Spacer(minLength: 0)
                    if let chip { chipView(chip) }
                }
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    if showThumbnails { thumbnails }
                    if let chip { chipView(chip) }
                }
            }
        }
    }

    private var thumbnails: some View {
        HStack(spacing: Theme.Spacing.s) {
            HStack(spacing: -10) {
                ForEach(model.analysisRecent, id: \.self) { id in
                    AssetThumbnail(id: id, side: 30)
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.card, lineWidth: 2))
                }
            }
            .accessibilityHidden(true)
            .transition(.opacity)
            Text("Gerade angesehen").font(.subheadline).foregroundStyle(.secondary)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: model.analysisRecent)
    }

    private var chipText: (text: LocalizedStringKey, symbol: String)? {
        guard !isPaused else { return nil }
        switch model.analysisBackground {
        case .running: return ("Läuft auch im Hintergrund", "arrow.triangle.2.circlepath")
        case .refused: return ("Läuft, solange Albumist offen ist", "iphone")
        case .idle: return nil
        }
    }

    private func chipView(_ chip: (text: LocalizedStringKey, symbol: String)) -> some View {
        Label(chip.text, systemImage: chip.symbol)
            .font(.footnote)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            .accessibilityIdentifier("analysis.background")
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
                Button { model.pauseAnalysis() } label: { CardTextButton("Pause") }
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
/// crossfade of the card).
struct AnalysisFinishedView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bounce = 0
    var photos: Int
    var proposals: Int

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(spacing: Theme.Spacing.s) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.bounce, value: bounce)
                    .accessibilityHidden(true)
                Text("Analyse fertig").font(.headline)
            }
            // How many photos are analysed says the plain card under it ("Alle 246 Fotos analysiert").
            Text(String(localized: "\(proposals) Vorschläge warten auf dich."))
                .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            if proposals > 0 {
                NavigationLink {
                    ProposalListView(area: nil)
                } label: {
                    Text("Vorschläge prüfen")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("analysis.review")
            }
        }
        .sensoryFeedback(.success, trigger: bounce) { _, new in new > 0 && !reduceMotion }
        .onAppear(perform: play)
        // Finished while the app was in the background: played when it is on screen again.
        .onChange(of: model.isOnScreen) { _, onScreen in if onScreen { play() } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("analysis.finished")
    }

    private func play() {
        guard model.claimFinishMoment(), !reduceMotion else { return }
        bounce += 1
    }
}

// MARK: - Details

/// "Details": all six steps with one sentence each and where they stand (rule 8).
struct AnalysisDetailsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        Text(summary(now: context.date))
                            .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityIdentifier("analysis.details.summary")
                    VStack(spacing: 0) {
                        ForEach(AnalysisStep.allCases, id: \.self) { step in
                            row(step)
                            if step != .proposals { Divider() }
                        }
                    }
                    Label("Alles passiert auf deinem iPhone. Nur für Städtenamen fragt Albumist bei Apple nach.", systemImage: "lock")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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

    /// "Fertig gegen 23:40 · 46 % · bisher 18 Min."
    private func summary(now: Date) -> String {
        var parts: [String] = []
        if let finish = model.analysisFinish, model.analysis.isRunning { parts.append(AnalysisText.finish(finish)) }
        parts.append(model.analysisBar.formatted(.percent.precision(.fractionLength(0))))
        if let start = model.analysisStartedAt, model.analysis.isRunning {
            let elapsed = Duration.seconds(max(60, now.timeIntervalSince(start)))
            parts.append(String(localized: "bisher \(elapsed.formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))"))
        }
        return parts.joined(separator: " · ")
    }

    private enum Standing { case done, running, later }

    private func standing(_ step: AnalysisStep) -> Standing {
        guard let current = model.analysis.step ?? model.analysis.stoppedAt?.step else {
            return model.analysis.lastReport?.isComplete == true ? .done : .later
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
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if standing == .running, model.analysis.isRunning, let left = model.analysisStepRemaining {
                    Text("noch etwa \(AnalysisText.left(left))")
                        .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                        .accessibilityLabel(Text("noch etwa \(AnalysisText.left(left, width: .wide))"))
                }
            }
        }
        .padding(.vertical, Theme.Spacing.m)
        .accessibilityElement(children: .combine)
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
            Text("fertig").font(.subheadline).foregroundStyle(.secondary)
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
        case .pausing: "pausing"
        case .paused: "paused"
        case .finished: "finished"
        }
    }
}
