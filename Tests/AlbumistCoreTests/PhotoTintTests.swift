import Foundation
import Testing
@testable import AlbumistCore

/// DS-11, Albumist's own handwriting: a calm colour taken from the photo on screen, behind a
/// suggestion's large cover. Taken from the photo's pixels (`PhotoTint.from`), as calm as a ground
/// can be and still be the photo's (no glow, no shine), and always readable: the small grey text
/// (`.noteText`) keeps 4.6:1, the accent and the page's sign ("Vorschlag · noch nicht in Fotos",
/// accent on 12 % accent) keep 4.5:1, light and dark. A photo without a colour of its own gives
/// none: the neutral ground stays.
@Suite("Photo tint")
struct PhotoTintTests {
    /// `width` × `height` pixels of one colour.
    static func image(_ color: SRGB, width: Int = 8, height: Int = 8) -> [UInt8] {
        let pixel = [color.red, color.green, color.blue].map { UInt8(($0 * 255).rounded()) } + [255]
        return Array([[UInt8]](repeating: pixel, count: width * height).joined())
    }

    /// Rows of colours, top to bottom, each `share` of the image's 20 rows.
    static func image(_ bands: [(SRGB, Int)], width: Int = 10) -> [UInt8] {
        bands.flatMap { color, rows in image(color, width: width, height: rows) }
    }

    static let red = SRGB(red: 0.80, green: 0.12, blue: 0.10)
    static let colourful: [(String, SRGB)] = [
        ("red", red),
        ("orange sunset", SRGB(red: 0.95, green: 0.55, blue: 0.20)),
        ("yellow", SRGB(red: 0.95, green: 0.85, blue: 0.20)),
        ("green forest", SRGB(red: 0.20, green: 0.45, blue: 0.18)),
        ("teal sea", SRGB(red: 0.10, green: 0.55, blue: 0.60)),
        ("blue sky", SRGB(red: 0.35, green: 0.60, blue: 0.95)),
        ("purple", SRGB(red: 0.45, green: 0.20, blue: 0.60)),
        ("pink", SRGB(red: 0.95, green: 0.55, blue: 0.70)),
        ("dark night", SRGB(red: 0.05, green: 0.08, blue: 0.20)),
        ("brown sand", SRGB(red: 0.76, green: 0.65, blue: 0.45)),
    ]

    // MARK: Contrast math

    @Test func contrastMathAgreesWithWCAG() {
        let black = SRGB(red: 0, green: 0, blue: 0), white = SRGB(red: 1, green: 1, blue: 1)
        #expect(abs(Contrast.ratio(black, white) - 21) < 0.001)
        #expect(Contrast.ratio(white, black) == Contrast.ratio(black, white))
        #expect(abs(Contrast.luminance(white) - 1) < 0.0001)
        // The app's own figures (Theme.swift): the note grey on the grouped background 5.3:1,
        // the accent on its 12 % ground on a white card 5.01:1.
        #expect(abs(Contrast.ratio(ThemeColors.noteTextLight, ThemeColors.groundLight) - 5.30) < 0.05)
        let pill = Contrast.over(ThemeColors.accentLight, opacity: 0.12, on: ThemeColors.cardLight)
        #expect(abs(Contrast.ratio(ThemeColors.accentLight, pill) - 5.01) < 0.05)
        #expect(Contrast.ratio(ThemeColors.noteTextDark, ThemeColors.groundDark) > 9)
    }

    @Test func oklabRoundTrips() {
        for (_, color) in Self.colourful + [("white", SRGB(red: 1, green: 1, blue: 1)), ("black", SRGB(red: 0, green: 0, blue: 0))] {
            let back = OKLab(color).srgb
            #expect(abs(back.red - color.red) < 0.002 && abs(back.green - color.green) < 0.002 && abs(back.blue - color.blue) < 0.002,
                    "\(color) → \(back)")
        }
        #expect(abs(OKLab(SRGB(red: 1, green: 1, blue: 1)).lightness - 1) < 0.001)
    }

    // MARK: The colour of a photo

    @Test func theTintIsThePhotosColourCalmed() throws {
        let tint = try #require(PhotoTint.from(rgba: Self.image(Self.red), width: 8, height: 8))
        // Light: a pale red, not red; dark: a deep red, nearly black.
        #expect(tint.light.red > tint.light.green && tint.light.red > tint.light.blue)
        #expect(tint.dark.red > tint.dark.green && tint.dark.red > tint.dark.blue)
        #expect(Contrast.luminance(tint.light) > 0.85)
        #expect(Contrast.luminance(tint.dark) < 0.012)
        // Calm: close to grey, far from the photo's red.
        #expect(tint.light.red - min(tint.light.green, tint.light.blue) < 0.08)
        #expect(OKLab(tint.light).chroma <= PhotoTint.lightChroma.upperBound + 0.001)
        #expect(OKLab(tint.dark).chroma <= PhotoTint.darkChroma.upperBound + 0.001)
    }

    /// Every colour a photo can have keeps the page readable: `.noteText` 4.6:1 and more (as
    /// Theme promises for it), the accent and the sign 4.5:1, light and dark; the ground stays
    /// below the cards in dark mode (they stand out from it, as from black).
    @Test func everyTintKeepsTheTextReadable() throws {
        for (name, color) in Self.colourful {
            let tint = try #require(PhotoTint.from(rgba: Self.image(color), width: 8, height: 8), "\(name)")
            #expect(Contrast.ratio(ThemeColors.noteTextLight, tint.light) >= 4.6, "\(name) light")
            #expect(Contrast.ratio(ThemeColors.noteTextDark, tint.dark) >= 4.6, "\(name) dark")
            #expect(Contrast.ratio(ThemeColors.accentLight, tint.light) >= 4.5, "\(name) light accent")
            #expect(Contrast.ratio(ThemeColors.accentDark, tint.dark) >= 4.5, "\(name) dark accent")
            let pillLight = Contrast.over(ThemeColors.accentLight, opacity: 0.12, on: tint.light)
            let pillDark = Contrast.over(ThemeColors.accentDark, opacity: 0.12, on: tint.dark)
            #expect(Contrast.ratio(ThemeColors.accentLight, pillLight) >= 4.5, "\(name) light sign")
            #expect(Contrast.ratio(ThemeColors.accentDark, pillDark) >= 4.5, "\(name) dark sign")
            #expect(Contrast.ratio(ThemeColors.labelLight, tint.light) >= 15, "\(name) light title")
            #expect(Contrast.ratio(ThemeColors.labelDark, tint.dark) >= 15, "\(name) dark title")
            #expect(Contrast.luminance(tint.dark) < Contrast.luminance(ThemeColors.cardDark), "\(name): the cards sink in")
            #expect(Contrast.luminance(tint.light) < Contrast.luminance(ThemeColors.cardLight), "\(name): the cards sink in")
            #expect(PhotoTint.check(tint), "\(name)")
        }
    }

    /// The photo's main colour leads, not a muddy average: a sky over sand is blue, not grey.
    @Test func theMainColourLeads() throws {
        let sky = SRGB(red: 0.30, green: 0.55, blue: 0.95), sand = SRGB(red: 0.85, green: 0.70, blue: 0.45)
        let beach = try #require(PhotoTint.from(rgba: Self.image([(sky, 14), (sand, 6)]), width: 10, height: 20))
        #expect(beach.light.blue > beach.light.red, "\(beach.light)")
        let dunes = try #require(PhotoTint.from(rgba: Self.image([(sky, 5), (sand, 15)]), width: 10, height: 20))
        #expect(dunes.light.red > dunes.light.blue, "\(dunes.light)")
        // The order of the pixels does not matter.
        let flipped = try #require(PhotoTint.from(rgba: Self.image([(sand, 6), (sky, 14)]), width: 10, height: 20))
        #expect(flipped == beach)
    }

    /// A photo without a colour of its own (grey, black, white, a document) gives no tint: the
    /// page keeps its neutral ground. Nor does an image that is not one.
    @Test func noColourNoTint() {
        for grey in [0.0, 0.2, 0.5, 0.8, 1.0] {
            #expect(PhotoTint.from(rgba: Self.image(SRGB(red: grey, green: grey, blue: grey)), width: 8, height: 8) == nil, "\(grey)")
        }
        // A nearly grey photo.
        #expect(PhotoTint.from(rgba: Self.image(SRGB(red: 0.52, green: 0.50, blue: 0.49)), width: 8, height: 8) == nil)
        #expect(PhotoTint.from(rgba: [], width: 0, height: 0) == nil)
        #expect(PhotoTint.from(rgba: [1, 2, 3], width: 8, height: 8) == nil, "too few bytes")
        #expect(PhotoTint.from(rgba: Self.image(Self.red), width: -1, height: 8) == nil)
        // Transparent pixels count for nothing.
        let clear = [UInt8](repeating: 0, count: 8 * 8 * 4)
        #expect(PhotoTint.from(rgba: clear, width: 8, height: 8) == nil)
    }

    /// A small bright spot on a grey photo does not paint the page: the ground follows the colour
    /// that covers the photo, weaker the less of it there is.
    @Test func aSmallSpotGivesAWeakerTint() throws {
        let grey = SRGB(red: 0.5, green: 0.5, blue: 0.5)
        let full = try #require(PhotoTint.from(rgba: Self.image(Self.red), width: 8, height: 8))
        let spot = PhotoTint.from(rgba: Self.image([(Self.red, 1), (grey, 19)]), width: 10, height: 20)
        if let spot {
            #expect(OKLab(spot.light).chroma < OKLab(full.light).chroma)
        }
    }

    /// The same photo gives the same tint every time (cached per photo, never a flicker).
    @Test func theTintIsStable() {
        let pixels = Self.image([(Self.colourful[4].1, 12), (Self.colourful[9].1, 8)])
        #expect(PhotoTint.from(rgba: pixels, width: 10, height: 20) == PhotoTint.from(rgba: pixels, width: 10, height: 20))
    }

    /// Pale in light mode, deep in dark mode, as UI test 3 reads the page's ground from its
    /// screenshot (verification review V9): each channel at least 215 of 255 in light mode and at
    /// most 80 in dark mode. Every tint keeps well inside, whatever its hue and strength (about
    /// 228 and 27 at the extremes), so the UI test fails only on a ground that is not one.
    @Test func everyTintIsPaleInLightAndDeepInDark() {
        var made = 0
        for degrees in stride(from: 0.0, to: 360.0, by: 5.0) {
            let angle = degrees * .pi / 180
            let hue = OKLab(lightness: 0.5, a: cos(angle) * 0.1, b: sin(angle) * 0.1)
            for strength in [PhotoTint.minimumStrength, 0.03, 0.06, 0.1, 0.2, 0.4] {
                guard let tint = PhotoTint.calm(hue, strength: strength) else { continue }
                made += 1
                for channel in [tint.light.red, tint.light.green, tint.light.blue] {
                    #expect(channel * 255 >= 215, "\(degrees)° at \(strength): light \(tint.light)")
                }
                for channel in [tint.dark.red, tint.dark.green, tint.dark.blue] {
                    #expect(channel * 255 <= 80, "\(degrees)° at \(strength): dark \(tint.dark)")
                }
            }
        }
        #expect(made >= 72 * 5, "\(made) tints made")
        for (name, color) in Self.colourful {
            guard let tint = PhotoTint.from(rgba: Self.image(color), width: 8, height: 8) else { continue }
            #expect([tint.light.red, tint.light.green, tint.light.blue].allSatisfy { $0 * 255 >= 215 }, "\(name): \(tint.light)")
            #expect([tint.dark.red, tint.dark.green, tint.dark.blue].allSatisfy { $0 * 255 <= 80 }, "\(name): \(tint.dark)")
        }
    }
}
