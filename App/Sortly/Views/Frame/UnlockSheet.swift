import SwiftUI
import UIKit
import SortlyCore

/// "Albumist freischalten" as a sheet of its own (design E6 "Freie Alben verbraucht", spec:
/// "eigenes Blatt, auch wenn „Anlegen“ auf der Karte an die Grenze kommt"): opened by "Anlegen"
/// on a card when the free albums are used up, and by the preview's unlock card. The app's icon,
/// what the purchase gives, one filled button with the App Store's price (`UnlockButton`: never
/// a price from the code), "Kauf wiederherstellen", and that nothing is lost. It closes by itself
/// once Albumist is unlocked; `onUnlocked` then goes on with what the user wanted.
struct UnlockSheet: View {
    enum Reason: Equatable {
        /// "Anlegen" on a card found the free albums used up.
        case quickCreate
        /// The preview needs `needed` albums, more than are still free.
        case preview(needed: Int)
    }

    var reason: Reason
    var onUnlocked: () -> Void = {}
    @Environment(Purchases.self) private var purchases
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var iconSide: CGFloat = 68

    var body: some View {
        NavigationRoot {
            ScrollView {
                VStack(spacing: Theme.Spacing.l) {
                    AppIconImage(side: iconSide)
                    VStack(spacing: Theme.Spacing.s) {
                        Text("Albumist freischalten")
                            .font(.title2.weight(.bold))
                            .accessibilityAddTraits(.isHeader)
                        explanation
                            .foregroundStyle(.noteText)
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    VStack(spacing: Theme.Spacing.xs) {
                        // Without a price: "Preis wird geladen …", not tappable (plugin review W7).
                        UnlockButton(prominent: true)
                        Button {
                            Task { await purchases.restore() }
                        } label: {
                            Text("Kauf wiederherstellen")
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .disabled(purchases.isPurchasing)
                        .accessibilityIdentifier("unlock.restore")
                    }
                    if let error = purchases.lastError {
                        ErrorNote(text: error)
                    }
                    if reason == .quickCreate {
                        Text("Der Vorschlag bleibt offen und läuft dir nicht weg.")
                            .font(.footnote).foregroundStyle(.noteText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.xl)
                .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("unlock.sheet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Label("Schließen", systemImage: "xmark") }
                        .accessibilityIdentifier("unlock.close")
                }
            }
        }
        // Half the screen as in the draft; the whole screen at the accessibility text sizes.
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
        // The price comes from StoreKit; a start without network is made up for here.
        .task { await purchases.loadProductIfNeeded() }
        // Bought or restored (also on another device of the same Apple Account): closes, and
        // what the user wanted goes on.
        .onChange(of: purchases.isUnlocked) { _, unlocked in
            guard unlocked else { return }
            dismiss()
            onUnlocked()
        }
    }

    @ViewBuilder
    private var explanation: some View {
        switch reason {
        case .quickCreate:
            Text("Deine \(Purchases.freeAlbumLimit) kostenlosen Alben sind angelegt. Mit einem einmaligen Kauf legst du unbegrenzt Alben an, ohne Abo.")
        case .preview(let needed):
            Text("Für diese Auswahl brauchst du \(needed) Alben. Kostenlos sind noch \(purchases.remainingFreeAlbums). Mit einem einmaligen Kauf sortierst du unbegrenzt, ohne Abo.")
        }
    }
}

/// The app's own icon as on the Home Screen, read from the app's bundle. A calm accent tile with
/// the albums symbol if iOS does not hand it out.
private struct AppIconImage: View {
    var side: CGFloat

    var body: some View {
        Group {
            if let icon = Self.primaryIcon() {
                Image(uiImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                Theme.accent.overlay {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: side * 0.42, weight: .semibold))
                        .foregroundStyle(Theme.onAccent)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.225, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        .accessibilityHidden(true)
    }

    /// The primary icon Xcode writes into the bundle (`CFBundleIcons`).
    private static func primaryIcon() -> UIImage? {
        guard let icons = Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] else { return nil }
        if let files = primary["CFBundleIconFiles"] as? [String], let name = files.last, let image = UIImage(named: name) {
            return image
        }
        return (primary["CFBundleIconName"] as? String).flatMap { UIImage(named: $0) }
    }
}
