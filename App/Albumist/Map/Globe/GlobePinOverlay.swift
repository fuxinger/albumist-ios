import SwiftUI
import AlbumistCore
import AlbumistMap

/// What SwiftUI shows above our Metal globe, set by `GlobeRenderer` once per drawn frame: the pins
/// where they stand on screen now, and a problem that keeps the globe from drawing. Observed, so
/// only the overlay redraws with each frame, never the page.
@MainActor
@Observable
final class GlobeOverlayModel {
    /// The pin groups of `MapPins.onGlobe`, placed with `GlobeOptics.place` (farther ones first).
    var pins: [GlobePlacedPin] = []
    /// Why the globe cannot draw (no Metal, a shader or the Earth image failed), in German.
    var problem: String?
}

/// The pins above our globe (concept §4.2): SwiftUI views, sharp at any zoom and read by
/// VoiceOver. They never take a touch: drags, pinches and taps go through to the globe.
struct GlobePinOverlay: View {
    let model: GlobeOverlayModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(model.pins) { placed in
                GlobePinView(pin: placed.group.pin, groupSize: placed.group.memberIDs.count)
                    .opacity(placed.opacity)
                    .position(x: CGFloat(placed.x), y: CGFloat(placed.y) - GlobePinView.tipOffset)
            }
        }
    }
}

/// One pin: a white-rimmed circle with the trip's photo (or, without one, a soft warm gradient
/// with the level's symbol), a small pointer whose tip stands on the place, and the count badge.
/// No shadows: sixty moving shadows would cost the GPU an extra pass each frame.
struct GlobePinView: View {
    let pin: MapPin
    let groupSize: Int

    static let side: CGFloat = 34
    static let pointer: CGFloat = 7
    /// From the view's centre down to the pointer's tip.
    static let tipOffset: CGFloat = (side + pointer) / 2

    var body: some View {
        ZStack(alignment: .top) {
            GlobePinPointer()
                .fill(Color.white)
                .frame(width: 14, height: Self.pointer + 6)
                .offset(y: Self.side - 6)
            face
        }
        .frame(width: Self.side, height: Self.side + Self.pointer, alignment: .top)
        .overlay(alignment: .topTrailing) {
            GlobePinBadge(count: pin.count)
                .offset(x: 8, y: -6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: GlobePinLabel.text(for: pin, groupSize: groupSize)))
    }

    private var face: some View {
        ZStack {
            Circle().fill(GlobePinStyle.gradient)
            cover
            Circle().strokeBorder(Color.white, lineWidth: 2.5)
            Circle().stroke(Color.black.opacity(0.22), lineWidth: 0.5)
        }
        .frame(width: Self.side, height: Self.side)
    }

    @ViewBuilder private var cover: some View {
        if let cover = pin.cover {
            AssetThumbnail(id: cover, side: Self.side)
                .environment(\.thumbnailShowsVideoLength, false)
                .frame(width: Self.side, height: Self.side)
                .clipShape(Circle())
        } else {
            Image(systemName: GlobePinStyle.symbol(for: pin.level))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white)
                .accessibilityHidden(true)
        }
    }
}

/// The pin's count on a small dark plate with a white rim (never text straight on the image).
struct GlobePinBadge: View {
    let count: Int

    var body: some View {
        Text(verbatim: count > 999 ? "999+" : "\(count)")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color.white)
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 18)
            .background { Capsule().fill(GlobePinStyle.badge) }
            .overlay { Capsule().strokeBorder(Color.white, lineWidth: 1.5) }
    }
}

/// The pointer under a pin: a triangle pointing down.
struct GlobePinPointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

@MainActor
enum GlobePinStyle {
    /// Warm like the arcs, from light gold to coral.
    static let gradient = LinearGradient(colors: [Color(red: 1.0, green: 0.80, blue: 0.42), Color(red: 0.93, green: 0.45, blue: 0.33)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
    static let badge = Color(red: 0.12, green: 0.12, blue: 0.13)

    static func symbol(for level: MapPinLevel) -> String {
        switch level {
        case .worldRegion: "globe.europe.africa.fill"
        case .country: "flag.fill"
        case .trip: "airplane"
        case .place: "camera.fill"
        }
    }
}

/// The German VoiceOver label of a pin: its name (the trip's or place's title, else the region
/// or country) and its count, and how many pins it stands for: "Lissabon, 34 Fotos",
/// "Portugal, 3 Reisen, und 2 weitere Stecknadeln".
enum GlobePinLabel {
    static let german = Locale(identifier: "de_DE")

    static func text(for pin: MapPin, groupSize: Int) -> String {
        var parts = [name(of: pin), count(of: pin)]
        if groupSize == 2 {
            parts.append("und 1 weitere Stecknadel")
        } else if groupSize > 2 {
            parts.append("und \(groupSize - 1) weitere Stecknadeln")
        }
        return parts.joined(separator: ", ")
    }

    static func name(of pin: MapPin) -> String {
        if let title = pin.title, !title.isEmpty { return title }
        switch pin.level {
        case .worldRegion:
            return pin.region.map(regionName) ?? "Weltgegend"
        case .country:
            return pin.countryKey.map(countryName) ?? "Land"
        case .trip:
            return "Reise"
        case .place:
            return "Ort"
        }
    }

    static func count(of pin: MapPin) -> String {
        let n = pin.count
        switch pin.level {
        case .worldRegion: return n == 1 ? "1 Land" : "\(n) Länder"
        case .country: return n == 1 ? "1 Reise" : "\(n) Reisen"
        case .trip, .place: return n == 1 ? "1 Foto" : "\(n) Fotos"
        }
    }

    /// A country's German name; a disputed area's key ("disputed-…") gets no country's name.
    static func countryName(_ key: String) -> String {
        guard key.count == 2 else { return "Umstrittenes Gebiet" }
        return german.localizedString(forRegionCode: key) ?? key
    }

    // One exhaustive switch that names each world region: a new region cannot be forgotten, and
    // splitting it would only hide the list.
    // swiftlint:disable:next cyclomatic_complexity
    static func regionName(_ region: WorldRegion) -> String {
        switch region {
        case .northernEurope: "Nordeuropa"
        case .westernEurope: "Westeuropa"
        case .southernEurope: "Südeuropa"
        case .easternEurope: "Osteuropa"
        case .northernAfrica: "Nordafrika"
        case .westernAfrica: "Westafrika"
        case .middleAfrica: "Zentralafrika"
        case .easternAfrica: "Ostafrika"
        case .southernAfrica: "Südliches Afrika"
        case .northernAmerica: "Nordamerika"
        case .centralAmerica: "Mittelamerika"
        case .caribbean: "Karibik"
        case .southAmerica: "Südamerika"
        case .centralAsia: "Zentralasien"
        case .easternAsia: "Ostasien"
        case .southEasternAsia: "Südostasien"
        case .southernAsia: "Südasien"
        case .westernAsia: "Westasien"
        case .australiaAndNewZealand: "Australien und Neuseeland"
        case .melanesia: "Melanesien"
        case .micronesia: "Mikronesien"
        case .polynesia: "Polynesien"
        case .antarctica: "Antarktis"
        }
    }
}

/// Why the globe cannot draw, on a dark plate (shown only when something failed).
struct GlobeProblemNote: View {
    let model: GlobeOverlayModel

    var body: some View {
        if let problem = model.problem {
            Text(verbatim: problem)
                .font(.footnote)
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.center)
                .padding(12)
                .background { RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.75)) }
                .padding(24)
        }
    }
}
