import SwiftUI
import SortlyCore
import SortlyEngine

/// "Dein Zuhause" in the settings: the home Albumist found (to confirm or correct), former homes
/// with their time, and other places of the user's where stays are not trips. Every change only
/// makes the suggestions again; albums and chosen suggestions stay as they are.

/// The settings row that leads to "Dein Zuhause".
struct HomeSettingsRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationLink {
            HomeSettingsView()
        } label: {
            LabeledContent {
                Text(HomeText.summary(model.homeSettings, detected: model.detectedHomePlace))
            } label: {
                Label("Dein Zuhause", systemImage: "house")
            }
        }
        .accessibilityIdentifier("settings.home")
    }
}

/// Texts of "Dein Zuhause", in one place so they read the same everywhere.
enum HomeText {
    /// The surroundings that count as home (the trip detection's home radius).
    static let radiusMeters = TripDetector.Configuration().homeRadiusMeters

    /// "München und Umgebung"; offline, where only the region is known, "Gegend in Bayern".
    static func area(_ components: PlaceComponents?) -> String {
        let name = HomeName(components)
        if let town = name.town { return String(localized: "\(town) und Umgebung") }
        if let region = name.region ?? name.country { return String(localized: "Gegend in \(region)") }
        return String(localized: "Ort ohne Namen")
    }

    /// The town (or region) alone: "München".
    static func short(_ components: PlaceComponents?) -> String {
        let name = HomeName(components)
        return name.town ?? name.region ?? name.country ?? String(localized: "Ort ohne Namen")
    }

    /// The value of the settings row.
    static func summary(_ settings: HomeSettings, detected: HomePlace?) -> String {
        switch settings.currentMode {
        case .confirmed: short(settings.confirmed?.components)
        case .none: String(localized: "Keins")
        case .automatic: detected.map { short($0.components) } ?? String(localized: "Noch nicht erkannt")
        }
    }

    /// "Bis Dezember 2018: Hamburg" (the last day the user lived there; `until` is the day after).
    static func former(_ home: FormerHome) -> String {
        let until = home.until.addingTimeInterval(-1).formatted(.dateTime.month(.wide).year())
        return String(localized: "Bis \(until): \(short(home.place.components))")
    }

    static func kind(_ kind: PersonalPlaceKind?) -> String {
        switch kind {
        case .parents: String(localized: "Eltern")
        case .secondHome: String(localized: "Zweitwohnung")
        case .work: String(localized: "Arbeit")
        case .other, nil: String(localized: "Anderer Ort")
        }
    }

    static func symbol(_ kind: PersonalPlaceKind?) -> String {
        switch kind {
        case .parents: "person.2"
        case .secondHome: "building.2"
        case .work: "briefcase"
        case .other, nil: "mappin.and.ellipse"
        }
    }

    /// The user's name for a place of theirs: their own word, else what it is ("Eltern"), else
    /// for an answer to "Bist du hier öfter?" the place's name.
    static func title(_ answer: PlaceAnswer, placeName: String?) -> String {
        if let label = answer.label, !label.isEmpty { return label }
        if answer.kind != nil { return kind(answer.kind) }
        return placeName ?? answer.name ?? String(localized: "Unbenannter Ort")
    }
}

/// "Dein Zuhause".
struct HomeSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var removingPlace: PlaceAnswer?

    var body: some View {
        Form {
            currentSection
            formerSection
            placesSection
        }
        .navigationTitle("Dein Zuhause")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Wieder als Reisen zeigen?", isPresented: Binding(get: { removingPlace != nil }, set: { if !$0 { removingPlace = nil } }),
                            titleVisibility: .visible, presenting: removingPlace) { answer in
            Button("Als Reisen zeigen") { Task { _ = await model.withdrawRecurringPlace(answer) } }
        } message: { _ in
            Text("Aufenthalte an diesem Ort werden wieder als Reisen vorgeschlagen. Schon angelegte Alben bleiben, wie sie sind.")
        }
    }

    // MARK: Current home

    @ViewBuilder
    private var currentSection: some View {
        Section {
            if model.homeChangeRunning {
                HStack(spacing: Theme.Spacing.m) {
                    ProgressView()
                    Text("Vorschläge werden angepasst …").foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            switch model.homeSettings.currentMode {
            case .confirmed:
                homeRow(title: HomeText.area(model.homeSettings.confirmed?.components),
                        detail: model.homeSettings.confirmedFrom == nil ? Text("Von dir festgelegt") : Text("Von dir bestätigt"), symbol: "house.fill")
                // The newest photos point somewhere else (moved since): said, never changed by itself.
                if let detected = model.detectedHomePlace, let chosen = model.homeSettings.confirmed,
                   GeoMath.distance(detected.center, chosen.center) > HomeText.radiusMeters {
                    Text("Deine neuesten Fotos sprechen für \(HomeText.area(detected.components)).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                changeLink(Text("Ändern"))
            case .none:
                homeRow(title: String(localized: "Kein Zuhause festgelegt"),
                        detail: Text("Alle Fotos mit Ort zählen für Länder und Orte."), symbol: "house.slash")
                changeLink(Text("Ändern"))
            case .automatic:
                if let detected = model.detectedHomePlace {
                    homeRow(title: HomeText.area(detected.components), detail: detectedDetail, symbol: "house")
                    if detected.components != nil {
                        Button {
                            Task { await model.confirmDetectedHome() }
                        } label: {
                            Label("Stimmt", systemImage: "checkmark")
                        }
                        .disabled(!model.canChangeHome)
                        .accessibilityIdentifier("home.confirm")
                        .accessibilityHint(Text("Albumist verwendet dieses Zuhause ab jetzt, auch wenn sich deine Fotos ändern."))
                    } else {
                        // No name yet: nothing to confirm that the user could recognise.
                        Text("Albumist kennt die Orte dort noch nicht. Sobald sie bekannt sind, kannst du dein Zuhause bestätigen.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    changeLink(Text("Ändern"))
                } else {
                    // Empty state: nothing detected yet, and why.
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Label("Noch kein Zuhause erkannt", systemImage: "house")
                            .font(.headline)
                        Text("Albumist erkennt dein Zuhause an Fotos mit Ort, die über mehrere Wochen in derselben Gegend entstehen. Dafür reicht es noch nicht, oder die Analyse ist noch nicht so weit.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                    .accessibilityElement(children: .combine)
                    changeLink(Text("Selbst wählen"))
                }
            }
        } header: {
            Text("Zuhause")
        } footer: {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                Text("Fotos aus deinem Zuhause und der Umgebung (etwa 30 km) sind keine Reise und brauchen kein eigenes Orte-Album.")
                Text("Änderungen passen nur die Vorschläge an. Deine Alben in Fotos und Vorschläge, die du schon ausgewählt hast, bleiben, wie sie sind.")
                if !model.canChangeHome && !model.homeChangeRunning {
                    Text("Während die Analyse oder das Anlegen läuft, kannst du hier nichts ändern.")
                }
            }
        }
    }

    private var detectedDetail: Text {
        if let since = model.detectedHome?.since {
            let month = since.formatted(.dateTime.month(.wide).year())
            return Text("Von Albumist erkannt, seit \(month)")
        }
        return Text("Von Albumist erkannt")
    }

    private func homeRow(title: String, detail: Text, symbol: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                detail.font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(Theme.accent)
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home.current")
    }

    private func changeLink(_ title: Text) -> some View {
        NavigationLink {
            HomePlacePicker(purpose: .current) { choice in
                Task {
                    switch choice {
                    case .place(let candidate): await model.chooseHome(candidate)
                    case .noHome: await model.chooseNoHome()
                    case .automatic: await model.chooseAutomaticHome()
                    }
                }
            }
        } label: {
            title
        }
        .disabled(!model.canChangeHome)
        .accessibilityIdentifier("home.change")
    }

    // MARK: Former homes

    private var formerSection: some View {
        Section {
            ForEach(model.homeSettings.former) { home in
                Label(HomeText.former(home), systemImage: "clock.arrow.circlepath")
            }
            .onDelete { offsets in
                let ids = Set(offsets.map { model.homeSettings.former[$0].id })
                Task { await model.removeFormerHomes(ids) }
            }
            .deleteDisabled(!model.canChangeHome)
            NavigationLink {
                FormerHomeEditor()
            } label: {
                Label("Früheres Zuhause hinzufügen", systemImage: "plus")
            }
            .disabled(!model.canChangeHome)
            .accessibilityIdentifier("home.addFormer")
        } header: {
            Text("Früher")
        } footer: {
            Text("Wenn du umgezogen bist: Reisen von damals misst Albumist am Zuhause von damals.")
        }
    }

    // MARK: Other places

    private var placesSection: some View {
        Section {
            ForEach(model.personalPlaces) { answer in
                let placeName = model.recurringPlaceProposal(for: answer)?.title ?? answer.name
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(HomeText.title(answer, placeName: placeName))
                        if answer.kind != nil || answer.label != nil, let placeName {
                            Text(placeName).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: HomeText.symbol(answer.kind)).foregroundStyle(Theme.accent)
                }
                .accessibilityElement(children: .combine)
                .swipeActions {
                    Button("Entfernen", role: .destructive) { removingPlace = answer }
                        .disabled(!model.canChangeHome)
                }
                .accessibilityAction(named: Text("Entfernen")) { if model.canChangeHome { removingPlace = answer } }
            }
            NavigationLink {
                PersonalPlaceEditor()
            } label: {
                Label("Ort hinzufügen", systemImage: "plus")
            }
            .disabled(!model.canChangeHome)
            .accessibilityIdentifier("home.addPlace")
        } header: {
            Text("Andere Orte")
        } footer: {
            Text("Zum Beispiel deine Eltern, eine Zweitwohnung oder die Arbeit. Aufenthalte dort zählen nicht als Reisen. Jeder Ort bekommt stattdessen ein eigenes Album.")
        }
    }
}

/// Choose a place from the user's own photos: towns (offline, regions), searchable.
struct HomePlacePicker: View {
    enum Purpose { case current, former, place }
    enum Choice { case place(HomeCandidate), noHome, automatic }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var purpose: Purpose
    var onPick: (Choice) -> Void
    @State private var query = ""

    private var candidates: [HomeCandidate] { HomeCandidates.filter(model.homeCandidates, query: query) }
    /// Picking the current home changes it at once: not while Albumist is busy. The other
    /// purposes only fill in a form.
    private var busy: Bool { purpose == .current && !model.canChangeHome }

    var body: some View {
        List {
            if busy {
                Text("Während die Analyse oder das Anlegen läuft, kannst du hier nichts ändern.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if purpose == .current && query.isEmpty {
                Section {
                    if model.homeSettings.currentMode != .automatic {
                        choiceButton(.automatic, title: Text("Automatisch erkennen"), detail: Text("Albumist erkennt dein Zuhause selbst."), symbol: "wand.and.stars")
                    }
                    if model.homeSettings.currentMode != .none {
                        choiceButton(.noHome, title: Text("Kein Zuhause festlegen"),
                                     detail: Text("Kein Ort gilt als Zuhause. Alle Fotos mit Ort zählen für Länder und Orte."), symbol: "house.slash")
                            .accessibilityIdentifier("home.noHome")
                    }
                }
            }
            Section {
                if candidates.isEmpty && !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else if candidates.isEmpty {
                    ContentUnavailableView {
                        Label("Noch keine Orte", systemImage: "mappin.slash")
                    } description: {
                        Text("Sobald Albumist die Orte deiner Fotos kennt, kannst du hier einen wählen.")
                    }
                }
                ForEach(candidates) { candidate in
                    Button {
                        onPick(.place(candidate))
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(HomeText.short(candidate.components)).foregroundStyle(.primary)
                            Text(detail(candidate)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("home.candidate")
                }
            } header: {
                if !candidates.isEmpty { Text("Orte aus deinen Fotos") }
            }
        }
        .searchable(text: $query, prompt: Text("Ort suchen"))
        .navigationTitle(purpose == .current ? Text("Zuhause wählen") : Text("Ort wählen"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func choiceButton(_ choice: Choice, title: Text, detail: Text, symbol: String) -> some View {
        Button {
            onPick(choice)
            dismiss()
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    title.foregroundStyle(.primary)
                    detail.font(.subheadline).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: symbol).foregroundStyle(Theme.accent)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .disabled(busy)
    }

    /// "Bayern, Deutschland · 120 Tage".
    private func detail(_ candidate: HomeCandidate) -> String {
        let parts = [candidate.components.locality == nil ? nil : candidate.components.administrativeArea, candidate.components.country]
            .compactMap { $0 }
        let days = String(localized: "\(candidate.photoDays) Tage mit Fotos")
        let region = parts.joined(separator: ", ")
        return parts.isEmpty ? days : String(localized: "\(region) · \(days)")
    }
}

/// "Früheres Zuhause hinzufügen": where, and until when.
struct FormerHomeEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var place: HomeCandidate?
    @State private var until = Calendar.current.date(byAdding: .year, value: -1, to: .now) ?? .now
    /// A tap is being stored: a second one waits (double tap).
    @State private var adding = false

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    HomePlacePicker(purpose: .former) { choice in
                        if case .place(let candidate) = choice { place = candidate }
                    }
                } label: {
                    LabeledContent("Ort") {
                        Text(place.map { HomeText.short($0.components) } ?? String(localized: "Wählen"))
                    }
                }
                DatePicker("Gewohnt bis", selection: $until, in: ...Date.now, displayedComponents: .date)
            } footer: {
                Text("Fotos bis zu diesem Tag misst Albumist an diesem Zuhause. Gab es davor noch ein Zuhause, füge es ebenso hinzu.")
            }
        }
        .navigationTitle("Früheres Zuhause")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Hinzufügen") {
                    guard let place, !adding else { return }
                    adding = true
                    Task {
                        // Not stored (Albumist was busy): the form stays, the user was told.
                        if await model.addFormerHome(place, until: until) { dismiss() }
                        adding = false
                    }
                }
                .disabled(place == nil || adding || !model.canChangeHome)
                .accessibilityIdentifier("home.former.add")
            }
        }
    }
}

/// "Ort hinzufügen": a place of the user's where stays are not trips ("Eltern", "Arbeit" …).
struct PersonalPlaceEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var kind: PersonalPlaceKind = .parents
    @State private var label = ""
    @State private var place: HomeCandidate?
    @State private var adding = false

    private var canAdd: Bool {
        place != nil && !adding && model.canChangeHome && (kind != .other || !label.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        Form {
            Section {
                Picker("Was ist das für ein Ort?", selection: $kind) {
                    ForEach(PersonalPlaceKind.allCases, id: \.self) { kind in
                        Label(HomeText.kind(kind), systemImage: HomeText.symbol(kind)).tag(kind)
                    }
                }
                .adaptivePickerStyle()
                TextField(kind == .other ? LocalizedStringKey("Name, zum Beispiel Oma") : LocalizedStringKey("Eigener Name (optional)"), text: $label)
                    .textInputAutocapitalization(.words)
            }
            Section {
                NavigationLink {
                    HomePlacePicker(purpose: .place) { choice in
                        if case .place(let candidate) = choice { place = candidate }
                    }
                } label: {
                    LabeledContent("Ort") {
                        Text(place.map { HomeText.short($0.components) } ?? String(localized: "Wählen"))
                    }
                }
            } footer: {
                Text("Aufenthalte dort zählen nicht als Reisen. Der Name ist nur für dich, das Album heißt wie der Ort.")
            }
        }
        .navigationTitle("Ort hinzufügen")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Hinzufügen") {
                    guard let place, !adding else { return }
                    adding = true
                    Task {
                        if await model.addPersonalPlace(place, kind: kind, label: label) { dismiss() }
                        adding = false
                    }
                }
                .disabled(!canAdd)
                .accessibilityIdentifier("home.place.add")
            }
        }
    }
}

/// On the overview after a change in "Dein Zuhause": what it did to the suggestions, until OK.
/// Like the card after re-checked suggestions: nothing in Photos changed.
struct HomeChangeCard: View {
    @Environment(AppModel.self) private var model
    var notice: HomeChangeNotice

    var body: some View {
        Card {
            Label("Zuhause geändert", systemImage: "house").font(.headline)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                if notice.removed > 0 {
                    Text("\(notice.removed) Vorschläge passen nicht mehr und sind weggefallen.")
                    if !notice.removedTitles.isEmpty {
                        Text(notice.removedTitles.joined(separator: ", ") + (notice.removed > notice.removedTitles.count ? " …" : ""))
                    }
                }
                if notice.added > 0 {
                    Text("\(notice.added) neue Vorschläge.")
                }
                if notice.held > 0 {
                    Text("\(notice.held) ausgewählte Vorschläge bleiben, wie du sie gewählt hast.")
                }
                Text("An deinen Alben in Fotos hat sich nichts geändert.")
            }
            .font(.subheadline).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Button("OK") { model.dismissHomeChangeNotice() }
                .buttonStyle(SecondaryButtonStyle())
                .accessibilityIdentifier("overview.homeChange.ok")
        }
    }
}
