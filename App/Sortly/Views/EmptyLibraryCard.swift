import SwiftUI
import SortlyCore
import SortlyEngine

/// What the overview shows instead of "0 von 0 sortiert" when the analysis is done and there
/// is nothing to suggest (plugin review K6: an App Review device with a handful of photos saw
/// "nothing happens"). It says what Albumist needs (photos with a date and a place, from trips
/// for example) and how to go on. For an empty or nearly empty library it offers the sample
/// photos (`SamplePhotos`), and says first that they really go into Photos.
/// Which case applies is decided in `EmptyLibraryState` (tested on Linux).
struct EmptyLibraryCard: View {
    @Environment(AppModel.self) private var model
    var state: EmptyLibraryState
    @State private var samples = SamplePhotos.shared
    @State private var confirmAdd = false
    @State private var confirmRemove = false

    /// Nil when the overview shows its normal status.
    static func state(for model: AppModel) -> EmptyLibraryState? {
        let analysis = model.analysis
        var year: Int?
        if case .year(let y) = model.analysisScope { year = y }
        let proposals = model.proposals.count
        var withPlace = 0
        if EmptyLibraryState.needsPlaceCount(proposals: proposals) {
            let scope = model.analysisScope, calendar = Calendar.sortlyDefault
            withPlace = model.facts.lazy.filter { $0.asset.location != nil && scope.includes($0, calendar: calendar) }.count
        }
        return EmptyLibraryState.evaluate(.init(
            photos: model.analysisCounts.photos, photosWithPlace: withPlace, proposals: proposals,
            analysisRunning: analysis.isRunning, analysisPaused: analysis.lastReport?.pausedBecause != nil || analysis.needsResume,
            analysedOnce: AnalysisMarker.completedOnce || analysis.lastReport?.isComplete == true,
            recounting: model.recount != nil, limitedAccess: model.access == .limited, trialYear: year,
            minimumPhotos: min(model.settings.places.minPhotos, model.settings.trips.minPhotos)))
    }

    var body: some View {
        let offersSamples = SampleLibrary.isOffered(photos: model.facts.count, access: model.access, samplesPresent: samples.arePresent)
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            VStack(spacing: Theme.Spacing.s) {
                Text(explanation)
                Text("Albumist braucht Fotos mit Datum und Ort, zum Beispiel von Reisen. Daraus schlägt es Alben für Länder und Reisen vor.")
            }
        } actions: {
            VStack(spacing: Theme.Spacing.s) {
                if samples.isAdding {
                    ProgressView(value: Double(samples.added), total: Double(max(samples.total, 1)))
                        .tint(Theme.accent)
                    Text("Beispielfotos werden angelegt: \(samples.added) von \(samples.total)")
                        .font(.footnote).foregroundStyle(.noteText).monospacedDigit()
                } else if offersSamples {
                    Button("Mit Beispielfotos ausprobieren") { confirmAdd = true }
                        .buttonStyle(PrimaryButtonStyle())
                        .accessibilityIdentifier("samples.add")
                }
                if samples.arePresent && !samples.isAdding {
                    Button("Beispielfotos wieder entfernen", role: .destructive) { confirmRemove = true }
                        .disabled(samples.isRemoving)
                }
                switch state {
                case .emptyTrialYear:
                    Button("Ganze Mediathek dazunehmen") { model.changeScope(.all) }
                        .buttonStyle(SecondaryButtonStyle())
                case .nothingShared:
                    EmptyView() // "Auswahl ändern" is on the card above
                default:
                    Button("Neu prüfen") { model.startAnalysis(cause: .tap) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        // A container of its own: an identifier on a plain container is handed down to every
        // element inside, so the sample-photos button lost its "samples.add" (run 43885771117).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.libraryHint")
        .confirmationDialog("Beispielfotos anlegen?", isPresented: $confirmAdd, titleVisibility: .visible) {
            Button("\(samples.count) Beispielfotos anlegen") { Task { await samples.add(model: model) } }
        } message: {
            Text("Albumist legt \(samples.count) Beispielfotos von vier Reisen in deiner Fotos-Mediathek an. Das ist nötig, damit Albumist daraus Alben anlegen kann. Du kannst sie jederzeit wieder entfernen: nur diese Beispielfotos und die Alben, die Albumist daraus gemacht hat.")
        }
        .confirmationDialog("Beispielfotos entfernen?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Beispielfotos entfernen", role: .destructive) { Task { await samples.remove(model: model) } }
        } message: {
            Text("Albumist löscht seine Beispielfotos, auch wenn du eines bearbeitet oder in ein eigenes Album gelegt hast, und die Alben, die es nur aus ihnen gemacht hat. iOS fragt vorher noch einmal; die Fotos liegen danach 30 Tage unter „Zuletzt gelöscht“. Deine eigenen Fotos und Alben bleiben, wie sie sind.")
        }
    }

    private var title: LocalizedStringKey {
        switch state {
        case .emptyLibrary: "Noch keine Fotos"
        case .nothingShared: "Noch keine Fotos freigegeben"
        case .emptyTrialYear(let year): "Keine Fotos aus \(String(year))"
        case .fewPhotos: "Noch zu wenige Fotos"
        case .noPlaces: "Fotos ohne Ort"
        case .nothingFound: "Noch keine Vorschläge"
        }
    }

    private var symbol: String {
        switch state {
        case .emptyLibrary, .nothingShared, .emptyTrialYear: "photo.on.rectangle.angled"
        case .fewPhotos: "photo.stack"
        case .noPlaces: "location.slash"
        case .nothingFound: "rectangle.stack"
        }
    }

    private var explanation: LocalizedStringKey {
        switch state {
        case .emptyLibrary:
            "Deine Mediathek ist leer. Neue Fotos erkennt Albumist von selbst."
        case .nothingShared:
            "Du hast Albumist noch keine Fotos freigegeben. Gib oben Fotos frei."
        case .emptyTrialYear(let year):
            "Albumist arbeitet nur mit Fotos aus \(String(year)). Nimm die ganze Mediathek dazu."
        case .fewPhotos(let count):
            "Albumist sieht erst \(count) Fotos. Für ein Album braucht es mehr Fotos von einem Ort oder einer Reise."
        case .noPlaces:
            "Keines deiner Fotos hat einen Aufnahmeort. Damit die Kamera ihn speichert: Einstellungen › Datenschutz & Sicherheit › Ortungsdienste › Kamera."
        case .nothingFound:
            "Albumist hat noch keinen Ort und keine Reise mit genug Fotos für ein eigenes Album gefunden. Neue Fotos prüft es von selbst."
        }
    }
}

/// "Beispielfotos wieder entfernen" in the settings, shown only while sample photos are there.
struct SamplePhotosSection: View {
    @Environment(AppModel.self) private var model
    @State private var samples = SamplePhotos.shared
    @State private var confirmRemove = false

    var body: some View {
        if samples.arePresent {
            Section {
                Button("Beispielfotos wieder entfernen", role: .destructive) { confirmRemove = true }
                    .disabled(samples.isAdding || samples.isRemoving)
                    .confirmationDialog("Beispielfotos entfernen?", isPresented: $confirmRemove, titleVisibility: .visible) {
                        Button("Beispielfotos entfernen", role: .destructive) { Task { await samples.remove(model: model) } }
                    } message: {
                        Text("Albumist löscht seine Beispielfotos, auch wenn du eines bearbeitet oder in ein eigenes Album gelegt hast, und die Alben, die es nur aus ihnen gemacht hat. iOS fragt vorher noch einmal; die Fotos liegen danach 30 Tage unter „Zuletzt gelöscht“. Deine eigenen Fotos und Alben bleiben, wie sie sind.")
                    }
            } footer: {
                Text("Die Beispielfotos hat Albumist zum Ausprobieren in deiner Mediathek angelegt.")
            }
        }
    }
}
