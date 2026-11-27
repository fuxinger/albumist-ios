import SwiftUI

/// How tall a sheet opens (design wave 3, DS-12b), one rule for every sheet of the app, said
/// where the sheet opens (`sheetSize(_:)` on its content):
/// - `.short`: a short explanation or a small form ("Sortiert", "Analyse", "Mehr erfahren",
///   "Anpassen", "Albumist freischalten", a photo's details) opens at half height and can be
///   pulled to the full height. Its content scrolls, so nothing is cut at half height.
/// - `.page`: a whole page with its own navigation (the settings, "Zu Album hinzufügen", the
///   trip workshop) opens at full height.
/// At the accessibility text sizes every sheet opens at full height only: half a screen shows
/// two lines there. The drag indicator is the system's, which shows it where a sheet has two
/// heights. No ground of the sheet's own: at half height a sheet is glass in iOS 26 (the photo
/// view's two solid sheets over the black viewer are the exception, see `PhotoViewer`).
enum SheetSize {
    case short
    case page

    /// The heights a sheet of this size may take at the text size `typeSize`.
    func detents(at typeSize: DynamicTypeSize) -> Set<PresentationDetent> {
        if self == .page || typeSize.isAccessibilitySize {
            return [.large]
        }
        return [.medium, .large]
    }
}

extension View {
    /// The heights of the sheet this view is the content of, by the app's rule (`SheetSize`).
    func sheetSize(_ size: SheetSize) -> some View {
        modifier(SheetSizeModifier(size: size))
    }
}

/// Reads the text size where the sheet shows, so the sheet follows it also while it is open.
private struct SheetSizeModifier: ViewModifier {
    let size: SheetSize
    @Environment(\.dynamicTypeSize) private var typeSize

    func body(content: Content) -> some View {
        content.presentationDetents(size.detents(at: typeSize))
    }
}
