import Foundation

/// The bars around the photo in the photo view (design wave 2, DS-10: "Tippen blendet alles
/// aus"). A tap on the photo hides them, the status bar and the home indicator, the next tap
/// brings them back, as in Photos. With VoiceOver or Switch Control running a tap never takes
/// the close, share and info buttons away: they are how those users leave and act.
public struct ViewerChrome: Equatable, Sendable {
    public private(set) var isShown = true

    public init() {}

    /// A tap on the photo (VoiceOver's double tap on it too). `assistive`: VoiceOver or Switch
    /// Control is running.
    public mutating func tap(assistive: Bool) {
        isShown = assistive || !isShown
    }

    /// VoiceOver or Switch Control was turned on or off: on brings hidden bars back, off changes
    /// nothing.
    public mutating func assistiveTechnology(running: Bool) {
        if running { isShown = true }
    }

    /// The photo was zoomed in: the bars go, as in Photos, so no title stands on the zoomed
    /// photo (design rule 1; review D, L6). A tap brings them back; with VoiceOver or Switch
    /// Control they stay.
    public mutating func zoomed(assistive: Bool) {
        if !assistive { isShown = false }
    }
}

/// When a Live Photo moves by itself (DS-10: "Live Photos bewegen sich"). As in Photos it plays
/// a short part of its motion once when it comes into view, but only where motion is welcome:
/// not with Reduce Motion, not in Low Power Mode, not with "Auto-Play Video Previews" off. A long
/// press plays it whole in every case: the user asked for it.
public enum LiveMotion {
    public static func playsHint(reduceMotion: Bool, lowPowerMode: Bool, autoplayVideos: Bool) -> Bool {
        !reduceMotion && !lowPowerMode && autoplayVideos
    }
}

/// Whether the photo view can share the photo it shows (DS-10: "Teilen"). Albumist never loads
/// a photo from iCloud (`isNetworkAccessAllowed = false` everywhere), so it shares only a photo
/// whose whole file is on the iPhone: a preview is not the photo.
public enum ShareAvailability: Equatable, Sendable {
    /// Not looked at yet: the button works, a tap looks first.
    case unknown
    /// The whole photo is on the iPhone.
    case onDevice
    /// Only a preview is on the iPhone, the photo itself is in iCloud.
    case onlyInICloud
    /// Photos has nothing to share (the photo is gone, or not a picture).
    case unavailable

    public var canShare: Bool { self == .unknown || self == .onDevice }
}

/// The name a shared photo gets (DS-10): the name Photos knows for it, as Photos shares it, so a
/// photo sent to a Mac or into Files is "IMG_1234.HEIC", never a random string. Photos hands an
/// edited photo out in another format than its original sometimes: then the name keeps the
/// original's name with the extension of the data. Never a path, never a hidden file.
public enum SharedPhotoFile {
    /// Extensions that name the same type: the original's spelling stays.
    private static let sameType: [Set<String>] = [["jpg", "jpeg", "jpe"], ["tif", "tiff"], ["heic", "heif"]]
    /// File names are at most 255 bytes; this leaves room for the folder's own needs.
    private static let longest = 200

    /// - Parameters:
    ///   - original: The original file name Photos knows (`PHAssetResource.originalFilename`).
    ///   - typeExtension: The extension of the data's type (`UTType.preferredFilenameExtension`).
    ///   - fallback: The name when Photos knows none ("Foto" / "Photo").
    public static func name(original: String?, typeExtension: String?, fallback: String) -> String {
        let type = typeExtension.flatMap { $0.isEmpty ? nil : $0 }
        var base = "", ext: String?
        if let original {
            let cleaned = clean(original)
            if let dot = cleaned.lastIndex(of: "."), dot != cleaned.startIndex {
                base = String(cleaned[..<dot])
                let after = String(cleaned[cleaned.index(after: dot)...])
                ext = after.isEmpty ? nil : after
            } else if cleaned.first == "." {
                ext = String(cleaned.dropFirst())
            } else {
                base = cleaned
            }
            // "Bericht.Version zwei und drei" has no extension: the rest is part of the name.
            if let long = ext, long.utf8.count > 16 || long.contains(" ") {
                base += "." + long
                ext = nil
            }
            base = String(base.drop { $0 == "." }).trimmingCharacters(in: .whitespaces)
        }
        guard !base.isEmpty else { return type.map { "\(fallback).\($0)" } ?? fallback }
        let kept: String?
        if let ext, let type {
            kept = same(ext, type) ? ext : type
        } else {
            kept = type ?? ext
        }
        let suffix = kept.map { "." + $0 } ?? ""
        return shortened(base, room: longest - suffix.utf8.count) + suffix
    }

    /// Path separators and the colon become a dash, control characters and line breaks go.
    private static func clean(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            switch scalar {
            case "/", "\\", ":": scalars.append("-")
            default:
                if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) { continue }
                scalars.append(scalar)
            }
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        let a = a.lowercased(), b = b.lowercased()
        return a == b || sameType.contains { $0.contains(a) && $0.contains(b) }
    }

    /// `base` cut at whole characters to at most `room` bytes.
    private static func shortened(_ base: String, room: Int) -> String {
        guard base.utf8.count > room else { return base }
        var shown = ""
        for character in base {
            guard shown.utf8.count + String(character).utf8.count <= room else { break }
            shown.append(character)
        }
        return shown
    }
}
