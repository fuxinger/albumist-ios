import SwiftUI

/// The app's icon as the Home Screen shows it, on the welcome page and in the purchase sheet.
/// An app cannot draw its own `AppIcon` set, so the same artwork is in the image set
/// `AppIconImage`, light and dark. The rounded square of iOS, a hairline edge that keeps its
/// shape on a light background, and a soft shadow that grows with the icon. Decorative: the
/// name beside or below it says what it is.
struct AppIconImage: View {
    var side: CGFloat

    var body: some View {
        // iOS rounds an icon's corners by about 22.4 % of its side (continuous corners).
        let shape = RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous)
        Image("AppIconImage")
            .resizable()
            .interpolation(.high)
            .frame(width: side, height: side)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5) }
            .shadow(color: Color(red: 10 / 255, green: 60 / 255, blue: 70 / 255).opacity(0.18),
                    radius: side * 0.134, y: side * 0.107)
            .accessibilityHidden(true)
    }
}
