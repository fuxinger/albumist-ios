import SwiftUI

/// The prototype page's own top bar (the page is a full-screen cover without a navigation
/// stack): its title with "Schließen", the choice of the view, and the choice of the data with
/// what that choice found.
struct MapPrototypeHeader: View {
    @Binding var tab: PrototypeTab
    @Binding var data: PrototypeData
    /// What the data choice found ("12 Reisen, …"), or why the demo stays.
    let note: String?
    /// The summary of the user's own trips is being made.
    let loading: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            titleRow
            tabPicker
            dataRow
            status
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }

    private var titleRow: some View {
        HStack(spacing: 12) {
            Text(verbatim: "Karten-Prototyp")
                .font(.headline)
                .foregroundStyle(Color.white)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            Button(action: onClose) {
                Text(verbatim: "Schließen")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.white)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityIdentifier("proto.close")
        }
    }

    private var tabPicker: some View {
        Picker(selection: $tab) {
            ForEach(PrototypeTab.allCases) { choice in
                Text(verbatim: choice.title).tag(choice)
            }
        } label: {
            Text(verbatim: "Ansicht")
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("proto.tabs")
    }

    /// Two buttons instead of a segmented control: the demo's label is too long for a segment.
    private var dataRow: some View {
        HStack(spacing: 8) {
            ForEach(PrototypeData.allCases) { choice in
                MapPrototypeChip(title: choice.title, selected: data == choice) { data = choice }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if loading {
            HStack(spacing: 8) {
                ProgressView()
                    .accessibilityHidden(true)
                Text(verbatim: "Deine Reisen werden zusammengefasst …")
                    .font(.footnote)
                    .foregroundStyle(Color.white.opacity(0.85))
            }
        } else if let note {
            Text(verbatim: note)
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(2)
                .accessibilityIdentifier("proto.dataNote")
        }
    }
}

/// One choice of the data: a button on a solid plate that shows whether it is chosen.
struct MapPrototypeChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(verbatim: title)
                .font(.footnote.weight(weight))
                .foregroundStyle(textColor)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(plate, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(traits)
    }

    private var weight: Font.Weight { selected ? .semibold : .regular }
    private var textColor: Color { selected ? Color.black : Color.white }
    private var plate: Color { selected ? Color.white : Color.white.opacity(0.16) }
    private var traits: AccessibilityTraits { selected ? .isSelected : [] }
}
