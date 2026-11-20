import SwiftUI
import UserNotifications
import SortlyCore
import SortlyEngine

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
