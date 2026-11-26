import SwiftUI
import AlbumistCore
import AlbumistMap

/// The photos of a short trip or of one place, shown one after another (a trip in one town, or
/// with two stations, has no film: Fuchs, 26.11.2026).
struct WorldPhotoStory: Identifiable {
    let id = UUID()
    let pages: [Page]

    struct Page: Hashable {
        let photo: AssetID
        let title: String
        let subtitle: String
    }

    init(trip: MapTrip, photos: TripPhotos, places: [Int]) {
        var pages: [Page] = []
        let when = WorldMapText.when(trip.geometry)
        var placeOf: [AssetID: Int] = [:]
        for index in places where photos.byPlace.indices.contains(index) {
            for id in photos.byPlace[index] { placeOf[id] = index }
        }
        // All of the trip's photos for the whole trip, only the places' photos for a place.
        let ids = places.count == trip.geometry.places.count ? photos.all : photos.photos(ofPlaces: places)
        for id in ids {
            let title = placeOf[id].map { WorldMapText.placeName(trip, $0) } ?? trip.title
            pages.append(Page(photo: id, title: title, subtitle: when))
        }
        self.pages = pages
    }
}

/// Full screen, one photo at a time: bars at the top show where the story is, a tap on the right
/// goes on, on the left back; each photo stays `secondsPerPhoto` and the story closes after the
/// last. With Reduce Motion the photos do not move on by themselves.
struct PhotoStoryView: View {
    static let secondsPerPhoto = 3.5
    let story: WorldPhotoStory
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0
    /// Round buttons grow with the text size (their size at the default text size).
    @ScaledMetric(relativeTo: .body) private var buttonSide: CGFloat = 44
    @State private var shownSince = Date.now

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if story.pages.indices.contains(index) {
                let page = story.pages[index]
                AssetThumbnail(id: page.photo, side: 600)
                    .ignoresSafeArea()
                    .id(page.photo)
                    .transition(.opacity)
                    .accessibilityLabel(Text(verbatim: "\(page.title), \(page.subtitle)"))
                    .accessibilityIdentifier("worldmap.story.photo")
                taps
                VStack(alignment: .leading) {
                    bars
                    Spacer()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: page.title).font(.title.weight(.bold))
                        Text(verbatim: page.subtitle).font(.body)
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 8)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.bottom, Theme.Spacing.xl)
                    .accessibilityHidden(true)
                }
            } else {
                ContentUnavailableView("Keine Fotos gefunden", systemImage: "photo")
                    .foregroundStyle(.white)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark").font(.body.weight(.semibold)).foregroundStyle(.white).frame(width: buttonSide, height: buttonSide)
                    .background(Color.black.opacity(0.4), in: Circle())
            }
            .accessibilityLabel(Text("Schließen"))
            .accessibilityIdentifier("worldmap.story.close")
            .padding(.top, Theme.Spacing.xl)
            .padding(.trailing, Theme.Spacing.l)
        }
        .statusBarHidden()
        .task(id: index) {
            shownSince = .now
            guard !reduceMotion, !story.pages.isEmpty else { return }
            try? await Task.sleep(for: .seconds(Self.secondsPerPhoto))
            guard !Task.isCancelled else { return }
            next()
        }
    }

    private var taps: some View {
        HStack(spacing: 0) {
            Color.clear.contentShape(Rectangle()).frame(maxWidth: .infinity)
                .onTapGesture { if index > 0 { withAnimation { index -= 1 } } }
                .accessibilityElement()
                .accessibilityLabel(Text("Vorheriges Foto"))
                .accessibilityAddTraits(.isButton)
            Color.clear.contentShape(Rectangle()).frame(maxWidth: .infinity).layoutPriority(1)
                .onTapGesture { next() }
                .accessibilityElement()
                .accessibilityLabel(Text("Nächstes Foto"))
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("worldmap.story.next")
        }
        .ignoresSafeArea()
    }

    private var bars: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let share = min(max(context.date.timeIntervalSince(shownSince) / Self.secondsPerPhoto, 0), 1)
            HStack(spacing: 3) {
                // Many photos: one bar for the story so far instead of a bar each.
                if story.pages.count > 20 {
                    bar(Double(index) + (reduceMotion ? 0 : share), of: Double(story.pages.count))
                } else {
                    ForEach(story.pages.indices, id: \.self) { i in
                        bar(i < index ? 1 : i == index ? (reduceMotion ? 0 : share) : 0, of: 1)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.m)
            .padding(.top, Theme.Spacing.s)
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Foto \(index + 1) von \(story.pages.count)"))
    }

    private func bar(_ value: Double, of total: Double) -> some View {
        GeometryReader { proxy in
            Capsule().fill(Color.white.opacity(0.35))
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.white).frame(width: proxy.size.width * min(max(value / total, 0), 1))
                }
        }
        .frame(height: 3)
    }

    private func next() {
        if index < story.pages.count - 1 {
            withAnimation { index += 1 }
        } else {
            dismiss()
        }
    }
}
