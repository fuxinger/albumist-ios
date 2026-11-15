import Foundation

/// What the app shows once it has loaded (plugin review W4).
///
/// The introduction only until it was finished once. When photo access is taken away later
/// in Settings, the introduction used to start again from its first page and ended with
/// "Analyse starten" for the whole library, so a part chosen before ("Nur 2025") was replaced
/// without the user asking for it. Now a screen of its own says that access is missing and
/// leads to Settings (or to the system question when iOS forgot the answer); once access is
/// back, Albumist goes on where it was, with the part of the library chosen before.
public enum StartScreen: Hashable, Sendable {
    /// First start: promise, areas, photo access, the part of the library to start with.
    case introduction
    /// The introduction was done, but Albumist may not read the photos (any more).
    case noPhotoAccess
    /// Overview, library, albums, search.
    case main

    public static func after(onboardingDone: Bool, access: LibraryAccess) -> StartScreen {
        guard onboardingDone else { return .introduction }
        return access.canRead ? .main : .noPhotoAccess
    }
}
