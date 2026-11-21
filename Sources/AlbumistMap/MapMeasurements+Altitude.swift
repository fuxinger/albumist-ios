import Foundation

// The altitude check of `MapMeasurements`: how many of the newest photos carry an altitude, and
// how exact it is.

extension MapMeasurements {
    // MARK: - Altitude of the photos

    /// One photo's location as PhotoKit has it (concept §13: "ob Fotos eine Höhen-Genauigkeit
    /// haben", for the record "Höchstes Foto").
    public struct AltitudeSample: Hashable, Sendable {
        public var hasLocation: Bool
        /// Metres above sea level; 0 when the camera wrote none.
        public var altitude: Double
        /// Metres; 0 or less when unknown.
        public var verticalAccuracy: Double

        public init(hasLocation: Bool, altitude: Double, verticalAccuracy: Double) {
            self.hasLocation = hasLocation
            self.altitude = altitude
            self.verticalAccuracy = verticalAccuracy
        }

        /// A photo without a location.
        public static let withoutLocation = AltitudeSample(hasLocation: false, altitude: 0, verticalAccuracy: 0)
    }

    /// How many of the newest photos carry an altitude and how exact it is: counts only.
    public struct AltitudeCheck: Hashable, Sendable, Codable {
        /// An altitude this exact or better counts as good enough for a summit.
        public static let goodVerticalAccuracyMeters = 30.0

        public var checkedAt: Date
        public var photos: Int
        public var withLocation: Int
        /// With a location whose altitude is a number other than 0.
        public var withAltitude: Int
        /// With a location whose vertical accuracy is a positive number.
        public var withVerticalAccuracy: Int
        /// The median of those vertical accuracies, in metres.
        public var medianVerticalAccuracy: Double?
        /// Vertical accuracy of `goodVerticalAccuracyMeters` or better.
        public var withinGoodAccuracy: Int

        public init(samples: [AltitudeSample], checkedAt: Date) {
            self.checkedAt = checkedAt
            photos = samples.count
            let located = samples.filter(\.hasLocation)
            withLocation = located.count
            withAltitude = located.filter { $0.altitude.isFinite && $0.altitude != 0 }.count
            let accuracies = located.map(\.verticalAccuracy).filter { $0.isFinite && $0 > 0 }
            withVerticalAccuracy = accuracies.count
            medianVerticalAccuracy = finite(MapMeasurements.median(accuracies))
            withinGoodAccuracy = accuracies.filter { $0 <= Self.goodVerticalAccuracyMeters }.count
        }
    }
}
