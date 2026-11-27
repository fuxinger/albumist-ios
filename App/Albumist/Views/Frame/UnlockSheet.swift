import StoreKit
import SwiftUI
import AlbumistCore

/// "Albumist freischalten" as a sheet of its own (design E6 "Freie Alben verbraucht", spec:
/// "eigenes Blatt, auch wenn „Anlegen“ auf der Karte an die Grenze kommt"): opened by "Anlegen"
/// on a card when the free albums are used up, and by "Freischalten …" on the preview's unlock
/// card. The app's icon, what the purchase gives, one filled button with the App Store's price
/// (`UnlockButton`: never a price from the code), "Kauf wiederherstellen" and "Code einlösen",
/// and that nothing is lost. It closes by itself once Albumist is unlocked; `onUnlocked` then
/// goes on with what the user wanted.
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
    @ScaledMetric(relativeTo: .largeTitle) private var iconSide: CGFloat = 68
    /// The App Store's sheet for an offer code.
    @State private var redeeming = false

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
                        Button {
                            redeeming = true
                        } label: {
                            Text("Code einlösen")
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .disabled(purchases.isPurchasing)
                        .accessibilityIdentifier("unlock.redeem")
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
        // The price comes from StoreKit; a start without network is made up for here.
        .task { await purchases.loadProductIfNeeded() }
        .offerCodeRedemption(isPresented: $redeeming) { _ in
            Task { await purchases.refreshEntitlements(mayLock: false) }
        }
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
            Text("""
                Für diese Auswahl brauchst du \(needed) Alben. Kostenlos sind noch \(purchases.remainingFreeAlbums). \
                Mit einem einmaligen Kauf sortierst du unbegrenzt, ohne Abo.
                """)
        }
    }
}
