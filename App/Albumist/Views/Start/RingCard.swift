import SwiftUI
import UserNotifications
import AlbumistCore
import AlbumistEngine

/// The card at the top of "Vorschläge" (overview draft B, 19.11.; design wave 1, E1 and E6): rows
/// under each other with a line between them, the ring on top, the analysis below, then
/// "Bescheid sagen, wenn fertig" while it may be asked. Each row brings its own margins, so a
/// row that opens something is highlighted edge to edge.
struct RingCardFrame<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: shape)
        .clipShape(shape)
        // White on light grey is only 1.1:1; with Increase Contrast the card gets an edge (as `Card`).
        .overlay {
            if contrast == .increased {
                shape.strokeBorder(Color(uiColor: .separator), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// The line between two rows of the ring card, from the text's margin to the edge.
struct RingCardSeparator: View {
    var body: some View {
        Divider().padding(.leading, Theme.Spacing.l)
    }
}

/// One row of the ring card: a column for the ring or a symbol, the row's words (one bold line,
/// one or two lines below in the note grey), and a chevron when the row opens a sheet. At the
/// accessibility text sizes the column moves above the words, which get the whole width.
struct RingCardRow<Lead: View, Detail: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The ring's column: 54 pt in the draft, growing with the text up to twice that.
    @ScaledMetric(relativeTo: .title3) private var column: CGFloat = 54
    private let lead: Lead
    private let title: Text
    private let titleFont: Font
    private let detail: Detail
    private let chevron: Bool

    init(title: Text, titleFont: Font = .headline, chevron: Bool = false, @ViewBuilder lead: () -> Lead,
         @ViewBuilder detail: () -> Detail) {
        self.title = title
        self.titleFont = titleFont
        self.chevron = chevron
        self.lead = lead()
        self.detail = detail()
    }

    var body: some View {
        let side = min(column, 108)
        let words = VStack(alignment: .leading, spacing: 2) {
            title
                .font(titleFont)
                .foregroundStyle(Color.primary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            detail
                .font(.subheadline)
                .foregroundStyle(.noteText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                    HStack {
                        lead.frame(width: side, height: side)
                        Spacer(minLength: 0)
                        if chevron { Self.chevronImage }
                    }
                    words
                }
            } else {
                HStack(spacing: 14) {
                    lead.frame(width: side, height: side)
                    words
                    if chevron { Self.chevronImage }
                }
            }
        }
        .padding(.leading, Theme.Spacing.l)
        .padding(.trailing, 14)
        .padding(.vertical, Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private static var chevronImage: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

/// A row of the ring card that opens something: highlighted while pressed, like a list row.
struct RingCardRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Color(uiColor: .systemFill) : Color.clear)
            .contentShape(Rectangle())
            .hoverEffect(.highlight)
    }
}

/// The sorted share as the card shows it (draft B: a 54 pt ring with the percent inside, small).
/// Below 1 it shows at most 99 % and reaches 100 % only when everything is sorted
/// (`Progress.shownShare`, as `ProgressRing`). Without `fraction` only the empty track, for
/// a spinner or a symbol inside.
struct SortedRing<Inside: View>: View {
    var fraction: Double?
    @ViewBuilder var inside: Inside
    @ScaledMetric(relativeTo: .title3) private var lineWidth: CGFloat = 6

    var body: some View {
        let width = min(lineWidth, 10)
        ZStack {
            Circle().stroke(Color(uiColor: .systemFill), lineWidth: width)
            if let fraction {
                let shown = OrganizationStatusResolver.Progress.shownShare(fraction)
                Circle()
                    .trim(from: 0, to: max(0.001, shown))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: width, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(shown, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
                    // Inside the ring the number shrinks rather than "6…" at large sizes.
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(width + 2)
                    .accessibilityHidden(true)
            }
            inside
        }
        .padding(width / 2)
    }
}

extension SortedRing where Inside == EmptyView {
    init(fraction: Double?) {
        self.init(fraction: fraction) { EmptyView() }
    }
}

// MARK: - The first 100 % (DS-08)

/// DS-08 (design wave 3): the one quiet moment when the first full analysis of this installation
/// reaches 100 % on screen (`FirstAnalysisMoment`). Above "Analyse fertig", where the progress
/// was: "100 %" in the wide figures and the analysis bar the user watched, whose six parts close
/// into one bar; a few seconds later it folds away and the card is the usual "Analyse fertig".
/// Once per installation (`FirstAnalysisMomentStore`).
///
/// - No haptic of its own: the success tap of "Analyse fertig" (`AnalysisFinishedView`) comes
///   with it, as it always did. Nothing flies (only the two moments of wave 2 do), nothing glows.
/// - Reduce Motion (and the UI runs, which show it only when a test asks for it): the bar shows
///   joined, the moment fades in and out.
/// - VoiceOver: said once ("Analyse fertig: 100 %"). The moment is decoration and hidden; "Analyse
///   fertig" below stays the element to read and to tap.
struct FirstAnalysisMomentHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var store = FirstAnalysisMomentStore.shared
    @State private var joined = false
    @State private var run: Task<Void, Never>?
    @ScaledMetric(relativeTo: .body) private var barHeight: CGFloat = 8

    /// Nothing moves: Reduce Motion, and the UI runs (their screenshots find it at rest).
    private var calm: Bool { reduceMotion || UITestSupport.isRunning }

    var body: some View {
        // Nothing while it does not play: due but not on screen yet (Control Center, a call), no
        // gap opens above "Analyse fertig".
        VStack(alignment: .leading, spacing: 0) {
            if store.moment.playing {
                moment
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear(perform: start)
        // The card came while Albumist was not on screen: it plays once Albumist is back, unless
        // it left for the background meanwhile (`FirstAnalysisMoment.leftScreen`).
        .onChange(of: model.isOnScreen) { _, onScreen in if onScreen { start() } }
        .onDisappear {
            run?.cancel()
            run = nil
            store.ended()
        }
    }

    private var moment: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(Self.percent)
                .font(.wideNumber(.largeTitle))
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            // The bar of the analysis that just finished, all six parts full (`AnalysisBar`).
            JoiningBar(shares: model.analysis.widths.shares, joined: calm || joined ? 1 : 0)
                .fill(Theme.accent)
                .frame(height: min(barHeight, 14))
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.top, Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Said once (`start`); UI runs find it by its identifier.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.spoken))
        .accessibilityIdentifier("analysis.firstFinish")
        .accessibilityHidden(!UITestSupport.isRunning)
    }

    /// "100 %" as the locale writes it.
    private static var percent: String { 1.0.formatted(.percent.precision(.fractionLength(0))) }

    private static var spoken: String { String(localized: "Analyse fertig: \(percent)") }

    /// The card with "Analyse fertig" is there: plays once, while due and on screen. It comes in
    /// with a fade, as "Analyse fertig" gives its check mark and its success tap.
    private func start() {
        typealias T = FirstAnalysisMoment.Timing
        guard run == nil, model.isOnScreen else { return }
        let claimed = withAnimation(calm ? .easeInOut(duration: T.fade) : .smooth(duration: T.fade)) {
            store.claim(onScreen: model.isOnScreen)
        }
        guard claimed else { return }
        var spoken = AttributedString(Self.spoken)
        spoken.accessibilitySpeechAnnouncementPriority = .low
        AccessibilityNotification.Announcement(spoken).post()
        run = Task { await play() }
    }

    /// The bar joins (not when calm), it stays a few seconds and folds away.
    private func play() async {
        typealias T = FirstAnalysisMoment.Timing
        if !calm {
            try? await Task.sleep(for: .seconds(T.joinDelay))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: T.join)) { joined = true }
        }
        let hold = FirstAnalysisMomentStore.askedByUITest ? T.heldForUITest : T.hold
        try? await Task.sleep(for: .seconds(calm ? hold : hold - T.joinDelay))
        guard !Task.isCancelled else { return }
        withAnimation(calm ? .easeInOut(duration: T.fade) : .smooth(duration: T.fold)) { store.ended() }
        run = nil
    }
}

/// The analysis bar at 100 % as its six parts close into one (DS-08,
/// `FirstAnalysisMoment.segments`). Animatable, so the join is drawn as a path per frame, not as
/// a view update.
struct JoiningBar: Shape {
    var shares: [Double]
    var joined: Double

    var animatableData: Double {
        get { joined }
        set { joined = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = rect.height / 2
        for part in FirstAnalysisMoment.segments(shares: shares, width: Double(rect.width), joined: joined) {
            let frame = CGRect(x: rect.minX + CGFloat(part.x), y: rect.minY, width: CGFloat(part.width), height: rect.height)
            let corner = min(radius, frame.width / 2)
            let leading = corner * CGFloat(part.leadingRound), trailing = corner * CGFloat(part.trailingRound)
            path.addRoundedRect(in: frame, cornerRadii: RectangleCornerRadii(topLeading: leading, bottomLeading: leading,
                                                                             bottomTrailing: trailing, topTrailing: trailing))
        }
        return path
    }
}

// MARK: - "Bescheid sagen, wenn fertig"

/// What iOS says about Albumist's notifications, and the question on the card (decision 3B,
/// 16.11.): Albumist no longer asks at the start of the analysis (two questions from iOS in a
/// row are easily declined, and a "no" can only be undone in the Settings app). It offers it
/// on the ring card once the analysis takes a while (`FinishNotice`), and iOS asks after the
/// tap. One per app, like the model.
@MainActor @Observable
final class FinishNotificationAsk {
    static let shared = FinishNotificationAsk()

    /// Nil until iOS answered: nothing is offered meanwhile.
    private(set) var permission: FinishNotice.Permission?
    /// The user allowed it on the card (this launch): the card says that it is promised.
    private(set) var allowedHere = false
    /// iOS asks right now: the button waits.
    private(set) var asking = false

    /// Reads what iOS knows now (on appearing, back from the Settings app).
    func refresh() async {
        permission = await Self.currentPermission()
    }

    /// "Bescheid sagen, wenn fertig": iOS asks; allowed, the card promises it.
    func ask() async {
        guard !asking else { return }
        asking = true
        defer { asking = false }
        let granted = await Self.requestPermission()
        permission = await Self.currentPermission()
        if granted && permission == .allowed { allowedHere = true }
    }

    nonisolated private static func currentPermission() async -> FinishNotice.Permission {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        switch status {
        case .notDetermined: return .notAsked
        case .authorized, .provisional, .ephemeral: return .allowed
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    nonisolated private static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }
}

/// The last row of the ring card while the analysis takes a while (`FinishNotice`): the offer
/// as a word in the accent with its bell, or, once allowed here, the promise.
struct FinishNotificationRow: View {
    var notice: FinishNotice
    @State private var ask = FinishNotificationAsk.shared

    var body: some View {
        switch notice {
        case .offer:
            Button {
                Task { await ask.ask() }
            } label: {
                Label("Bescheid sagen, wenn fertig", systemImage: "bell")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.vertical, Theme.Spacing.s)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            }
            .buttonStyle(RingCardRowButtonStyle())
            .disabled(ask.asking)
            .accessibilityIdentifier("analysis.notify")
        case .promised:
            Label("Albumist sagt Bescheid, wenn die Analyse fertig ist.", systemImage: "bell.badge")
                .font(.subheadline)
                .foregroundStyle(.noteText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, Theme.Spacing.m)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("analysis.notify.promised")
        }
    }
}
