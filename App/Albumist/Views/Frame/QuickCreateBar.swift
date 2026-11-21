import SwiftUI
import AlbumistCore

/// Right after "Anlegen" on a card (design decision 7B, draft E6 "Nach „Anlegen“"): the album's
/// name with "angelegt" and "Widerrufen", above the tab bar, like the note after "Ignorieren"
/// (`IgnoreUndoBar`) and the one Mail shows after moving a message. It goes by itself after a
/// few seconds, later with VoiceOver (`QuickCreate.bannerDuration`); afterwards the history
/// makes it undone like every change. While "Widerrufen" runs, a spinner stands
/// beside it, and when the album is deleted the banner says first that iOS asks once more
/// (P3-07): the iOS question follows right after.
struct QuickCreateBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Empty without a banner, so the inset takes no room; it slides in and out (a fade with
        // Reduce Motion).
        ZStack {
            if let banner = model.quickCreateBanner { note(banner) }
        }
        .animation(.smooth(duration: 0.35), value: model.quickCreateBanner?.id)
    }

    private func note(_ banner: QuickCreateBanner) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            AdaptiveStack(spacing: Theme.Spacing.m) {
                Label {
                    Text("„\(banner.title)“ angelegt")
                        .compactLineLimit(2)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                }
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    Task { await model.undoQuickCreate() }
                } label: {
                    Text("Widerrufen").checkingBeside(!banner.canUndo)
                }
                .font(.subheadline.weight(.semibold))
                .disabled(!banner.canUndo)
                .minimumHitTarget()
                .accessibilityIdentifier("quickCreate.undo")
            }
            if case .undoing(deletesAlbum: true) = banner.phase {
                DeleteQuestionNote.text
                    .font(.footnote).foregroundStyle(.noteText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.xs)
        .floatingPanel(cornerRadius: 22)
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.bottom, Theme.Spacing.s)
        // A container of its own: the button inside keeps "quickCreate.undo".
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quickCreate.banner")
        .motionAwareTransition(.move(edge: .bottom).combined(with: .opacity))
    }
}

extension View {
    /// The banner after "Anlegen" at the bottom of a tab's screens, above the tab bar (and above
    /// a screen's own bar at the bottom). Without a banner it takes no room.
    func showsQuickCreateBanner() -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            QuickCreateBar()
        }
    }
}

private struct QuickCreateAtOnceKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether "Anlegen" makes the album at once on this stack (decision 7B): only on the tabs,
    /// which show the banner with "Widerrufen", the purchase sheet and the messages
    /// (`MainTabs`). Elsewhere, such as in a sheet over the tabs (a photo's "Info"), all of them
    /// would be hidden under the sheet: there a card opens its suggestion and "Album anlegen" the
    /// preview, as before 7B. Every `NavigationRoot` sets it for its own stack, so a sheet never
    /// inherits the yes of the tab under it (review B of design wave 1).
    var quickCreateAtOnce: Bool {
        get { self[QuickCreateAtOnceKey.self] }
        set { self[QuickCreateAtOnceKey.self] = newValue }
    }
}
