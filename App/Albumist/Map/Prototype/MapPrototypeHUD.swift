import QuartzCore
import SwiftUI
import AlbumistMap

/// The live measurements of the view shown, on a solid dark plate above the map: read twice a
/// second from `PrototypeMetrics.live` (the logs themselves are not observed, so a frame redraws
/// nothing), folded to its first line on demand. UI tests read the numbers from the
/// accessibility value of "proto.hud".
struct MapPrototypeHUD: View {
    let metrics: PrototypeMetrics
    let source: MetricSource
    @Binding var isOpen: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            MapPrototypeHUDPlate(lines: currentLines(), isOpen: $isOpen)
        }
    }

    /// The lines at this tick of the timeline.
    private func currentLines() -> [String] {
        MapMeasurements.hudLines(metrics.live(source, now: CACurrentMediaTime()))
    }
}

/// The HUD's look: the lines in white on black at 0.75 opacity, with a button that folds them
/// to the first line.
struct MapPrototypeHUDPlate: View {
    let lines: [String]
    @Binding var isOpen: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Text(verbatim: shownText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .accessibilityLabel(Text(verbatim: "Messwerte"))
                .accessibilityValue(Text(verbatim: lines.joined(separator: "; ")))
                .accessibilityIdentifier("proto.hud")
            foldButton
        }
        .padding(.leading, 12)
        .background(Color.black.opacity(0.75))
    }

    private var shownText: String {
        let shown: [String] = isOpen ? lines : Array(lines.prefix(1))
        return shown.joined(separator: "\n")
    }

    private var foldButton: some View {
        Button {
            isOpen.toggle()
        } label: {
            Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.white)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(Text(verbatim: isOpen ? "Messwerte einklappen" : "Messwerte aufklappen"))
        .accessibilityIdentifier("proto.hudFold")
    }
}
