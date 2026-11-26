import MapKit
import UIKit
import AlbumistCore
import AlbumistMap

// The annotations of Apple's map after the handover (HandoverMapView.swift): the pins of a
// level, the rounded home, and the view that draws a pin with its photo.

/// The shown pin of a group on Apple's map after the handover (`MapPins.onGlobe`).
final class AppleMapsPinAnnotation: NSObject, MKAnnotation {
    let pin: AlbumistMap.MapPin
    let coordinate: CLLocationCoordinate2D

    init(pin: AlbumistMap.MapPin) {
        self.pin = pin
        self.coordinate = AppleMapsBridge.coordinate(pin.coordinate)
        super.init()
    }
}

/// The rounded home (`RoundedHome`, about 10 km): never the exact one.
final class AppleMapsHouseAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        super.init()
    }
}

/// A pin on Apple's map: the image of `AppleMapsArt.pin`, first with the soft gradient, then with
/// the pin's photo once it is loaded from the iPhone (`ThumbnailCache`, never from iCloud).
@MainActor final class AppleMapsPinAnnotationView: MKAnnotationView {
    static let reuseName = "albumist.apple-maps.pin"

    private var shownPin: AlbumistMap.MapPin?
    private var photoLoad: Task<Void, Never>?

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        displayPriority = .required
        collisionMode = .circle
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        photoLoad?.cancel()
        photoLoad = nil
        shownPin = nil
    }

    func show(_ pin: AlbumistMap.MapPin) {
        shownPin = pin
        image = AppleMapsArt.pin(photo: nil, count: pin.count)
        accessibilityLabel = AppleMapsText.pinLabel(pin)
        photoLoad?.cancel()
        photoLoad = nil
        guard let cover = pin.cover else { return }
        photoLoad = Task { [weak self] in
            let photo = await ThumbnailCache.shared.image(for: cover, side: AppleMapsStyle.pinSide)
            guard let self, !Task.isCancelled, self.shownPin == pin, let photo else { return }
            self.image = AppleMapsArt.pin(photo: photo, count: pin.count)
        }
    }
}
