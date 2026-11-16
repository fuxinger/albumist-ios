import SwiftUI
import SortlyCore

/// The one-time purchase button, in the plan preview and in the settings (plugin review W7).
/// Without a price from the App Store it says "Preis wird geladen …" and cannot be tapped, and
/// the price is loaded again with growing pauses while the button is on screen (a start
/// without network). Rules: `PurchaseRules.unlockButton`.
struct UnlockButton: View {
    @Environment(Purchases.self) private var purchases
    /// The big accent button of the plan preview; plain in the settings list.
    var prominent = false

    var body: some View {
        if prominent {
            button.buttonStyle(PrimaryButtonStyle())
        } else {
            button
        }
    }

    @ViewBuilder
    private var button: some View {
        let state = PurchaseRules.unlockButton(hasPrice: purchases.product != nil, isPurchasing: purchases.isPurchasing)
        Button {
            Task { await purchases.purchase() }
        } label: {
            switch state {
            case .purchasing:
                ProgressView().tint(prominent ? Theme.onAccent : nil)
                    .accessibilityLabel(Text("Kauf läuft"))
            case .buy:
                if let product = purchases.product {
                    Text("Freischalten für \(product.displayPrice)")
                }
            case .loadingPrice:
                HStack(spacing: Theme.Spacing.s) {
                    ProgressView().tint(prominent ? Theme.onAccent : nil)
                        .accessibilityHidden(true) // the text beside it says what runs
                    Text("Preis wird geladen …")
                }
            }
        }
        .disabled(!state.isEnabled)
        .accessibilityIdentifier("unlock.buy")
        .task {
            var attempt = 0
            while purchases.product == nil, !Task.isCancelled {
                await purchases.loadProductIfNeeded()
                guard purchases.product == nil else { break }
                try? await Task.sleep(for: .seconds(PurchaseRules.priceRetryDelay(attempt: attempt)))
                attempt += 1
            }
        }
    }
}
