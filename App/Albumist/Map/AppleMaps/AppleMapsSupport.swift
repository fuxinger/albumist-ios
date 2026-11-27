import MapKit
import SwiftUI
import UIKit
import AlbumistCore
import AlbumistMap

// What Apple's three map views of the prototype share (Apple's globe, the map after the handover,
// the trip playback): coordinates in MapKit's type, the arcs' and pins' look, and the pins'
// accessibility words. The arcs and pins look as the prototype brief says for every view: warm
// white to sun-gold arcs, white-rimmed round photo pins with a small count badge, the house on a
// solid plate, no text directly on the imagery.

/// Coordinates between the map core (`GeoCoordinate`) and MapKit (`CLLocationCoordinate2D`).
enum AppleMapsBridge {
    static func coordinate(_ coordinate: GeoCoordinate) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    static func geo(_ coordinate: CLLocationCoordinate2D) -> GeoCoordinate {
        GeoCoordinate(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

/// The look of arcs, pins and the house on Apple's maps (prototype brief: arcs #FFF4D6 to #FFC94D,
/// pins about 34 pt).
enum AppleMapsStyle {
    /// A pin's diameter in points.
    static let pinSide: CGFloat = 34
    /// The white rim round a pin's photo.
    static let pinRim: CGFloat = 2
    /// Room left under Apple's map after the handover for the page's controls, so Apple's logo and
    /// "Rechtliches" stay visible above them (MKMapView places both inside its layout margins).
    static let handoverBottomMargin: CGFloat = 56

    /// Warm white, where an arc leaves home.
    static var arcStart: Color { Color(red: 1, green: 0.957, blue: 0.839) }
    /// Sun-gold, where it arrives.
    static var arcEnd: Color { Color(red: 1, green: 0.788, blue: 0.302) }
    static var arcStartUIColor: UIColor { UIColor(red: 1, green: 0.957, blue: 0.839, alpha: 1) }
    static var arcEndUIColor: UIColor { UIColor(red: 1, green: 0.788, blue: 0.302, alpha: 1) }

    /// Along an arc from home to the destination (MapKit lays a polyline's gradient along it).
    static var arcGradient: LinearGradient {
        LinearGradient(colors: [arcStart, arcEnd], startPoint: .leading, endPoint: .trailing)
    }

    /// A little thicker the more trips an arc carries: 1.5 pt for one, up to 3.5 pt for five or more.
    static func arcWidth(weight: Int) -> CGFloat {
        1.5 + CGFloat(min(max(weight - 1, 0), 4)) * 0.5
    }

    static func arcStroke(weight: Int) -> StrokeStyle {
        StrokeStyle(lineWidth: arcWidth(weight: weight), lineCap: .round, lineJoin: .round)
    }

    /// The soft fill of a pin without a photo (the demo has none).
    static var pinGradient: LinearGradient {
        LinearGradient(colors: [Color(red: 0.98, green: 0.80, blue: 0.55), Color(red: 0.83, green: 0.45, blue: 0.38)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var pinGradientUIColors: [UIColor] {
        [UIColor(red: 0.98, green: 0.80, blue: 0.55, alpha: 1), UIColor(red: 0.83, green: 0.45, blue: 0.38, alpha: 1)]
    }

    /// The solid dark plate under any text or symbol on a map.
    static var plate: Color { Color.black.opacity(0.75) }
}

/// What VoiceOver says for a pin: no coordinates, the pin's own words.
enum AppleMapsText {
    static func pinLabel(_ pin: AlbumistMap.MapPin) -> String {
        let count = PlaybackText.grouped(pin.count)
        switch pin.level {
        case .worldRegion:
            return "\(count) \(pin.count == 1 ? "Land" : "Länder")"
        case .country:
            let name = pin.countryKey.flatMap { Locale(identifier: "de_DE").localizedString(forRegionCode: $0) } ?? "Land"
            return "\(name) · \(count) \(pin.count == 1 ? "Reise" : "Reisen")"
        case .trip, .place:
            return "\(pin.title ?? "Ort") · \(count) \(pin.count == 1 ? "Foto" : "Fotos")"
        }
    }

    static let house = "Zuhause, auf etwa 10 km gerundet"
}

// MARK: - SwiftUI pins (Apple's globe)

/// A pin on Apple's globe: the pin's photo (or a soft gradient) in a white-rimmed circle, with the
/// count on a small dark badge.
struct AppleMapsPinBubble: View {
    let pin: AlbumistMap.MapPin

    var body: some View {
        AppleMapsPinFace(cover: pin.cover)
            .overlay(alignment: .topTrailing) { badge }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: AppleMapsText.pinLabel(pin)))
    }

    @ViewBuilder private var badge: some View {
        if pin.count > 1 {
            AppleMapsCountBadge(count: pin.count)
                .offset(x: 8, y: -6)
        }
    }
}

/// The round face of a pin.
struct AppleMapsPinFace: View {
    let cover: AssetID?

    var body: some View {
        face
            .frame(width: AppleMapsStyle.pinSide, height: AppleMapsStyle.pinSide)
            .clipShape(Circle())
            .overlay { Circle().strokeBorder(Color.white, lineWidth: AppleMapsStyle.pinRim) }
            .shadow(color: Color.black.opacity(0.35), radius: 3, x: 0, y: 1)
    }

    @ViewBuilder private var face: some View {
        if let cover {
            AssetThumbnail(id: cover, side: AppleMapsStyle.pinSide)
                .environment(\.thumbnailShowsVideoLength, false)
        } else {
            AppleMapsStyle.pinGradient
        }
    }
}

/// The number on a pin, on a dark capsule (never on the imagery itself).
struct AppleMapsCountBadge: View {
    let count: Int

    var body: some View {
        Text(verbatim: PlaybackText.grouped(count))
            .font(.caption2.weight(.bold))
            .monospacedDigit()
            .foregroundStyle(Color.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(AppleMapsStyle.plate))
    }
}

/// The rounded home's house on a solid plate.
struct AppleMapsHousePlate: View {
    var body: some View {
        Image(systemName: "house.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.white)
            .padding(7)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(AppleMapsStyle.plate))
            .accessibilityLabel(Text(verbatim: AppleMapsText.house))
    }
}

// MARK: - UIKit pins (Apple's map after the handover)

/// The images of pins and the house for `MKAnnotationView`, drawn like the SwiftUI pins above.
@MainActor enum AppleMapsArt {
    /// A pin with `photo` (aspect-filled) or the soft gradient, and its count badge. The image is
    /// square with the circle in its middle, so the pin's centre stands on its coordinate.
    static func pin(photo: UIImage?, count: Int) -> UIImage {
        let side = AppleMapsStyle.pinSide
        let label = count > 1 ? PlaybackText.grouped(count) as NSString : nil
        let font = UIFont.systemFont(ofSize: 11, weight: .bold)
        let textSize = label?.size(withAttributes: [.font: font]) ?? .zero
        let badge = CGSize(width: max(textSize.width + 10, 18), height: 16)
        // Room round the circle for the badge at its top right corner, the same on every side.
        let pad = max(4, badge.width / 2 - 2, badge.height / 2 + 2)
        let canvas = side + 2 * pad
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: canvas, height: canvas))
        return renderer.image { context in
            let cg = context.cgContext
            let circle = CGRect(x: pad, y: pad, width: side, height: side)
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: 1), blur: 3, color: UIColor.black.withAlphaComponent(0.35).cgColor)
            UIColor.white.setFill()
            UIBezierPath(ovalIn: circle).fill()
            cg.restoreGState()
            let face = circle.insetBy(dx: AppleMapsStyle.pinRim, dy: AppleMapsStyle.pinRim)
            cg.saveGState()
            UIBezierPath(ovalIn: face).addClip()
            if let photo, photo.size.width > 0, photo.size.height > 0 {
                let scale = max(face.width / photo.size.width, face.height / photo.size.height)
                let size = CGSize(width: photo.size.width * scale, height: photo.size.height * scale)
                photo.draw(in: CGRect(x: face.midX - size.width / 2, y: face.midY - size.height / 2, width: size.width, height: size.height))
            } else {
                drawGradient(in: face, context: cg)
            }
            cg.restoreGState()
            if let label {
                let plate = CGRect(x: circle.maxX - 4 - badge.width / 2, y: circle.minY + 4 - badge.height / 2, width: badge.width, height: badge.height)
                UIColor.black.withAlphaComponent(0.8).setFill()
                UIBezierPath(roundedRect: plate, cornerRadius: badge.height / 2).fill()
                let origin = CGPoint(x: plate.midX - textSize.width / 2, y: plate.midY - textSize.height / 2)
                label.draw(at: origin, withAttributes: [.font: font, .foregroundColor: UIColor.white])
            }
        }
    }

    /// The house ("house.fill") in white on a dark rounded plate.
    static func house() -> UIImage {
        let size = CGSize(width: 28, height: 28)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let plate = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1), cornerRadius: 7)
            UIColor.black.withAlphaComponent(0.8).setFill()
            plate.fill()
            let configuration = UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            guard let symbol = UIImage(systemName: "house.fill", withConfiguration: configuration)?
                .withTintColor(UIColor.white, renderingMode: .alwaysOriginal) else { return }
            symbol.draw(at: CGPoint(x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2))
        }
    }

    private static func drawGradient(in rect: CGRect, context: CGContext) {
        let colors = AppleMapsStyle.pinGradientUIColors.map(\.cgColor) as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return }
        context.drawLinearGradient(gradient, start: CGPoint(x: rect.minX, y: rect.minY), end: CGPoint(x: rect.maxX, y: rect.maxY), options: [])
    }
}
