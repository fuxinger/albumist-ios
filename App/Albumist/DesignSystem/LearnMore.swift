import SwiftUI

/// Short help (≤ 2 lines) plus a "Mehr erfahren" button that shows the full text in a sheet.
///
/// Decision 8A: help texts on a page are at most two lines; the rest is one tap away, any time
/// ("Was zählt als sortiert?"). The short text is the note grey on cards and the grouped
/// background (`Theme.noteText`, 4.6:1 and more); at the accessibility text sizes it wraps as far
/// as it needs. The button is a word in the accent, 44 pt high to tap. The sheet has the title as
/// a heading, the full text, and "Fertig"; it scrolls at large text sizes.
struct LearnMore: View {
    private let short: Text
    private let full: Text
    private let title: Text
    @State private var showsFull = false

    init(short: Text, full: Text, title: Text) {
        self.short = short
        self.full = full
        self.title = title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            short
                .font(.footnote)
                .foregroundStyle(.noteText)
                .compactLineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                showsFull = true
            } label: {
                Text("Mehr erfahren")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(title)
            .accessibilityIdentifier("learnMore.open")
        }
        .sheet(isPresented: $showsFull) {
            LearnMoreSheet(title: title, full: full)
                .sheetSize(.short)
        }
    }
}

/// The full help text: its title as a heading, the text, "Fertig".
private struct LearnMoreSheet: View {
    let title: Text
    let full: Text
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationRoot {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    title
                        .font(.title2.weight(.bold))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    full
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("learnMore.text")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.bottom, Theme.Spacing.xl)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                        .accessibilityIdentifier("learnMore.done")
                }
            }
        }
    }
}
