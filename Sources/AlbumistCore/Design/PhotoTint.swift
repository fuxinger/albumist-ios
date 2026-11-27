import Foundation

/// A colour in sRGB, each channel 0…1.
public struct SRGB: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Each channel kept inside 0…1.
    var clamped: SRGB {
        SRGB(red: min(max(red, 0), 1), green: min(max(green, 0), 1), blue: min(max(blue, 0), 1))
    }
}

/// Contrast as WCAG 2 counts it (relative luminance, ratio 1…21), and colours laid over each
/// other as the screen composites them (in sRGB).
public enum Contrast {
    public static func luminance(_ color: SRGB) -> Double {
        let c = color.clamped
        return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
    }

    public static func ratio(_ a: SRGB, _ b: SRGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `top` at `opacity` over `ground`: the sign's capsule (`Theme.accent.opacity(0.12)`).
    public static func over(_ top: SRGB, opacity: Double, on ground: SRGB) -> SRGB {
        let o = min(max(opacity, 0), 1)
        return SRGB(red: top.red * o + ground.red * (1 - o), green: top.green * o + ground.green * (1 - o),
                    blue: top.blue * o + ground.blue * (1 - o))
    }

    static func linear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func encoded(_ c: Double) -> Double {
        c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }
}

/// A colour in Oklab (Björn Ottosson, 2020; the space CSS Color 4 uses): lightness 0…1, and a
/// and b, whose angle is the hue and whose length the chroma. Lightness and chroma change here
/// without the hue drifting, as it would in HSB.
public struct OKLab: Hashable, Sendable {
    public var lightness: Double
    public var a: Double
    public var b: Double

    public init(lightness: Double, a: Double, b: Double) {
        self.lightness = lightness
        self.a = a
        self.b = b
    }

    public init(_ color: SRGB) {
        let r = Contrast.linear(color.red), g = Contrast.linear(color.green), bl = Contrast.linear(color.blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl)
        lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    }

    public var chroma: Double { (a * a + b * b).squareRoot() }

    /// The colour in sRGB, each channel kept inside 0…1.
    public var srgb: SRGB {
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        return SRGB(red: Contrast.encoded(max(0, r)), green: Contrast.encoded(max(0, g)),
                    blue: Contrast.encoded(max(0, bl))).clamped
    }

    /// The same hue at another lightness and chroma.
    func with(lightness: Double, chroma: Double) -> OKLab {
        let own = self.chroma
        guard own > 0 else { return OKLab(lightness: lightness, a: 0, b: 0) }
        return OKLab(lightness: lightness, a: a / own * chroma, b: b / own * chroma)
    }
}

/// The app's colours a tint is checked against: `Theme.noteText` (normal contrast; Increase
/// Contrast never gets a tint), the accent of `AccentColor`, the system's grouped background,
/// cards and labels. Kept equal to the App's by `PhotoTintSourceTests`.
public enum ThemeColors {
    public static let noteTextLight = SRGB(red: 0.39, green: 0.39, blue: 0.42)
    public static let noteTextDark = SRGB(red: 0.67, green: 0.67, blue: 0.70)
    public static let accentLight = SRGB(red: 0.039, green: 0.431, blue: 0.478)
    public static let accentDark = SRGB(red: 0.322, green: 0.765, blue: 0.792)
    /// `systemGroupedBackground`.
    public static let groundLight = SRGB(red: 0.949, green: 0.949, blue: 0.969)
    public static let groundDark = SRGB(red: 0, green: 0, blue: 0)
    /// `secondarySystemGroupedBackground`.
    public static let cardLight = SRGB(red: 1, green: 1, blue: 1)
    public static let cardDark = SRGB(red: 0.110, green: 0.110, blue: 0.118)
    public static let labelLight = SRGB(red: 0, green: 0, blue: 0)
    public static let labelDark = SRGB(red: 1, green: 1, blue: 1)
}

/// Albumist's own handwriting (DS-11, design wave 3): a calm colour taken from the photo on
/// screen, for the ground behind it, light and dark.
///
/// What Apple does, and what is taken from it:
/// - Music (iOS 26.4): an album's artwork runs into a background in its own colour, and the
///   list stands on it with black or white text. Taken: the photo's colour carries on into the
///   page's ground. Not taken: its strength. In dark mode a light artwork gave a bright page
///   ("flash bang"), and Increase Contrast had to tone it down: here dark stays dark and
///   Increase Contrast gets the neutral ground at once.
/// - Photos' Memories and the App Store's Today cards: the colour comes from the main colour of
///   the picture, not from a muddy average of all its colours; text never sits on the photo
///   itself. Taken: the main colour (`from`), the text on a quiet ground below the photo.
///
/// How it is made (`from`): the pixels of the small image already in memory are read in Oklab;
/// grey, very dark and very bright pixels carry no colour. The hues are sorted into twelve
/// sectors, and the sector with the largest summed chroma leads (how much of the photo has that
/// hue, weighted by how strong it is there): mostly the colour that covers most of the photo,
/// but a small, very saturated area can beat a large muted one; its share of the photo softens
/// that in how strong the tint gets (`share * 3`, full from a third of the photo on). The ground
/// keeps that hue at a fixed lightness (`lightLightness`, `darkLightness`)
/// and a small chroma (`lightChroma`, `darkChroma`): a flat colour, no gradient, no glow. Then
/// it is checked (`check`): `.noteText` 4.6:1 and more, the accent and the page's sign 4.5:1,
/// the cards still lighter than the ground; if not, the lightness moves away from the text
/// until it is, and without a safe one there is no tint. A photo without a colour of its own
/// gives none (nil): the page keeps its neutral ground.
public struct PhotoTint: Hashable, Sendable {
    public var light: SRGB
    public var dark: SRGB

    public init(light: SRGB, dark: SRGB) {
        self.light = light
        self.dark = dark
    }

    /// As light as the grouped background or a touch lighter: the sign's accent on its 12 %
    /// capsule keeps 4.5:1 only there (4.52:1 on the plain background).
    public static let lightLightness = 0.968
    /// Darker than the cards (`secondarySystemGroupedBackground`, Oklab lightness 0.2275), so
    /// they still stand out from it, though less than from black: 1.12 to 1.13 : 1 on the tint
    /// against 1.23 : 1 on black (second review, K9; worth a look on a device with a red or a
    /// blue cover).
    public static let darkLightness = 0.17
    public static let lightChroma = 0.008...0.022
    public static let darkChroma = 0.008...0.026
    /// Below this the photo has no colour of its own.
    public static let minimumStrength = 0.012
    /// What `.noteText` keeps on the ground, as Theme promises it everywhere.
    public static let noteContrast = 4.6
    /// What the accent and the page's sign keep (WCAG AA for text).
    public static let accentContrast = 4.5

    /// The tint of an image given as RGBA bytes (8 bits each, sRGB, `width` × `height`, row by
    /// row; transparent pixels count for nothing). Nil when the image has no colour of its own,
    /// or the bytes are not such an image.
    public static func from(rgba bytes: [UInt8], width: Int, height: Int) -> PhotoTint? {
        guard width > 0, height > 0, bytes.count >= width * height * 4 else { return nil }
        let sectors = 12
        var sums = [(a: Double, b: Double, count: Double, chroma: Double)](repeating: (0, 0, 0, 0), count: sectors)
        var counted = 0.0
        for index in 0..<(width * height) {
            let at = index * 4
            guard bytes[at + 3] >= 128 else { continue }
            counted += 1
            let lab = OKLab(SRGB(red: Double(bytes[at]) / 255, green: Double(bytes[at + 1]) / 255,
                                 blue: Double(bytes[at + 2]) / 255))
            let chroma = lab.chroma
            // Grey, nearly black or nearly white: no colour to speak of.
            guard chroma >= 0.03, lab.lightness > 0.12, lab.lightness < 0.98 else { continue }
            var angle = atan2(lab.b, lab.a)
            if angle < 0 { angle += 2 * .pi }
            let sector = min(sectors - 1, Int(angle / (2 * .pi) * Double(sectors)))
            sums[sector].a += lab.a
            sums[sector].b += lab.b
            sums[sector].count += 1
            sums[sector].chroma += chroma
        }
        guard counted > 0, let main = sums.max(by: { $0.chroma < $1.chroma }), main.count > 0 else { return nil }
        let share = main.count / counted
        let strength = main.chroma / main.count * min(1, share * 3)
        guard strength >= minimumStrength else { return nil }
        let hue = OKLab(lightness: 0.5, a: main.a / main.count, b: main.b / main.count)
        return calm(hue, strength: strength)
    }

    /// The ground for `hue` (its a and b) at `strength` (chroma, 0…0.4): pale in light mode,
    /// deep in dark mode, checked (`check`).
    static func calm(_ hue: OKLab, strength: Double) -> PhotoTint? {
        let lightC = min(max(strength * 0.3, lightChroma.lowerBound), lightChroma.upperBound)
        let darkC = min(max(strength * 0.3, darkChroma.lowerBound), darkChroma.upperBound)
        guard let light = safe(hue, in: Lightnesses(start: lightLightness, step: 0.004, end: 0.99), chroma: lightC, isLight: true),
              let dark = safe(hue, in: Lightnesses(start: darkLightness, step: -0.01, end: 0.08), chroma: darkC, isLight: false) else {
            return nil
        }
        return PhotoTint(light: light, dark: dark)
    }

    /// The lightnesses `safe` tries: from `start` towards `end`, `step` at a time (below zero
    /// towards the dark).
    private struct Lightnesses {
        var start: Double
        var step: Double
        var end: Double
    }

    /// The first lightness of `lightnesses` whose colour passes the checks.
    private static func safe(_ hue: OKLab, in lightnesses: Lightnesses, chroma: Double, isLight: Bool) -> SRGB? {
        let (step, end) = (lightnesses.step, lightnesses.end)
        var lightness = lightnesses.start
        while step > 0 ? lightness <= end + 1e-9 : lightness >= end - 1e-9 {
            let color = hue.with(lightness: lightness, chroma: chroma).srgb
            if isLight ? passesLight(color) : passesDark(color) { return color }
            lightness += step
        }
        return nil
    }

    static func passesLight(_ ground: SRGB) -> Bool {
        let sign = Contrast.over(ThemeColors.accentLight, opacity: 0.12, on: ground)
        return Contrast.ratio(ThemeColors.noteTextLight, ground) >= noteContrast
            && Contrast.ratio(ThemeColors.accentLight, ground) >= accentContrast
            && Contrast.ratio(ThemeColors.accentLight, sign) >= accentContrast
            && Contrast.luminance(ground) < Contrast.luminance(ThemeColors.cardLight)
    }

    static func passesDark(_ ground: SRGB) -> Bool {
        let sign = Contrast.over(ThemeColors.accentDark, opacity: 0.12, on: ground)
        return Contrast.ratio(ThemeColors.noteTextDark, ground) >= noteContrast
            && Contrast.ratio(ThemeColors.accentDark, ground) >= accentContrast
            && Contrast.ratio(ThemeColors.accentDark, sign) >= accentContrast
            && Contrast.luminance(ground) < Contrast.luminance(ThemeColors.cardDark)
    }

    /// Whether both grounds keep every text on them readable (`from` only makes such tints).
    public static func check(_ tint: PhotoTint) -> Bool {
        passesLight(tint.light) && passesDark(tint.dark)
    }
}
