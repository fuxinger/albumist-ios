import SwiftUI
import AlbumistCore
import AlbumistMap

/// The 60-second test of the view shown: "60-s-Test", and while a test runs a button that
/// cancels it and counts down the seconds left (once a second).
struct MapPrototypeTestButton: View {
    let metrics: PrototypeMetrics
    let onStart: () -> Void

    var body: some View {
        if metrics.runningTest == nil {
            PrototypeButton(title: "60-s-Test", prominent: true, action: onStart)
                .accessibilityIdentifier("proto.test")
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                PrototypeButton(title: cancelTitle(at: context.date), prominent: true) { metrics.cancelTest() }
                    .accessibilityIdentifier("proto.testCancel")
            }
        }
    }

    private func cancelTitle(at date: Date) -> String {
        "Abbrechen · noch \(metrics.secondsLeft(at: date) ?? 0) s"
    }
}

/// The texts under the page's buttons: the result of the shown view's last test (of this visit,
/// else the one kept from before) and what the last tool said.
struct MapPrototypeNotes: View {
    let metrics: PrototypeMetrics
    let source: MetricSource
    let toolNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if metrics.runningTest == nil, let result = metrics.results[source] {
                MapPrototypeNote(text: MapMeasurements.summary(result), lines: 4)
                    .accessibilityIdentifier("proto.testResult")
            }
            if let toolNote {
                MapPrototypeNote(text: toolNote, lines: 3)
                    .accessibilityIdentifier("proto.toolNote")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One of the page's notes: white footnote text on the dark controls.
struct MapPrototypeNote: View {
    let text: String
    let lines: Int

    var body: some View {
        Text(verbatim: text)
            .font(.footnote)
            .foregroundStyle(Color.white.opacity(0.85))
            .lineLimit(lines)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The tools of our globe: the jump to Iceland (where the owner judges the Earth image's
/// sharpness just above the handover), the flight through the handover, and the globe's layers.
struct MapPrototypeGlobeTools: View {
    @Binding var layers: PrototypeLayers
    let onIceland: () -> Void
    let onHandover: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            PrototypeButton(title: "Island", prominent: false, action: onIceland)
                .accessibilityIdentifier("proto.iceland")
            PrototypeButton(title: "Übergabe", prominent: false, action: onHandover)
                .accessibilityIdentifier("proto.handover")
            layerMenu
        }
    }

    private var layerMenu: some View {
        Menu {
            Toggle(isOn: $layers.showsPins) { Text(verbatim: "Stecknadeln") }
            Toggle(isOn: $layers.showsArcs) { Text(verbatim: "Bögen") }
            Toggle(isOn: $layers.showsTint) { Text(verbatim: "Tönung") }
        } label: {
            PrototypeButtonLabel(title: "Ebenen", prominent: false)
        }
        .accessibilityIdentifier("proto.layers")
    }
}

/// The trip "Reise abspielen" plays: the demo trip, or one of the user's own trips (newest
/// first) from a menu. Trip titles are shown on this page only, never in a report.
struct MapPrototypeTripPicker: View {
    let trips: [MapTrip]
    @Binding var selection: AlbumistID?
    let current: MapTrip

    var body: some View {
        if trips.isEmpty {
            Text(verbatim: "Demo-Reise „\(current.title)“, \(Self.days(current)), ohne Fotos")
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        } else {
            Menu {
                ForEach(trips) { trip in
                    Button {
                        selection = trip.id
                    } label: {
                        Text(verbatim: Self.label(trip))
                    }
                }
            } label: {
                PrototypeButtonLabel(title: "Reise: \(Self.label(current))", prominent: false)
            }
            .accessibilityIdentifier("proto.trip")
        }
    }

    /// "Island, Ringstraße · 9 Tage · 07.2024".
    static func label(_ trip: MapTrip) -> String {
        let first = trip.geometry.firstDay
        return "\(trip.title) · \(days(trip)) · " + String(format: "%02d.%04d", first.month, first.year)
    }

    static func days(_ trip: MapTrip) -> String {
        let count = trip.geometry.days
        return count == 1 ? "1 Tag" : "\(count) Tage"
    }
}

/// A button of the page's controls: a solid plate with white text (dark text on the prominent
/// one), at least 44 pt high.
struct PrototypeButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PrototypeButtonLabel(title: title, prominent: prominent)
        }
        .buttonStyle(.plain)
    }
}

/// The look of `PrototypeButton`, also the label of the page's menus.
struct PrototypeButtonLabel: View {
    let title: String
    let prominent: Bool

    var body: some View {
        Text(verbatim: title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(textColor)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(plate, in: RoundedRectangle(cornerRadius: 12))
    }

    private var textColor: Color { prominent ? Color.black : Color.white }
    private var plate: Color { prominent ? Color.white : Color.white.opacity(0.16) }
}
