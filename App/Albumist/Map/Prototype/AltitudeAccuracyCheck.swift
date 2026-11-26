import CoreLocation
import Foundation
import Photos
import AlbumistMap

/// Whether the owner's photos carry an altitude and how exact it is (concept 2.0 §13, wave 0:
/// "ob Fotos eine Höhen-Genauigkeit haben", for the record "Höchstes Foto"). Reads PhotoKit's
/// metadata of the newest images only: never an image, never anything from iCloud, and only
/// counts leave this check (`MapMeasurements.AltitudeCheck`).
enum AltitudeAccuracyCheck {
    /// The newest images looked at.
    static let photoLimit = 2_000

    /// The check of the newest `photoLimit` images, made off the main thread; `nil` without
    /// access to the photos (the page then says so calmly).
    static func run() async -> MapMeasurements.AltitudeCheck? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        let limit = photoLimit
        return await Task.detached(priority: .userInitiated) { () -> MapMeasurements.AltitudeCheck in
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.fetchLimit = limit
            let assets = PHAsset.fetchAssets(with: .image, options: options)
            var samples: [MapMeasurements.AltitudeSample] = []
            samples.reserveCapacity(assets.count)
            for index in 0..<assets.count {
                guard let location = assets.object(at: index).location else {
                    samples.append(.withoutLocation)
                    continue
                }
                samples.append(MapMeasurements.AltitudeSample(hasLocation: true, altitude: location.altitude,
                                                              verticalAccuracy: location.verticalAccuracy))
            }
            return MapMeasurements.AltitudeCheck(samples: samples, checkedAt: Date())
        }.value
    }
}
