import Foundation
import AlbumistCore

// The parts of a `PlaybackPlan` and of the picture it gives at a time: its days, stops and legs,
// the camera, the frame and the route.

/// One calendar day of the playback.
public struct PlaybackDay: Hashable, Sendable {
    /// From 0; "Tag 3 von 9" is index 2.
    public var index: Int
    /// The local calendar day (`TripGeometry.firstDay` plus `index`).
    public var day: LocalDay
    /// Seconds from the playback's start.
    public var start: Double
    public var end: Double
    /// The trip's photos on the map that day (`TripGeometry.dayCounts`).
    public var photoCount: Int
    /// The places of the day's stops, in route order (empty for a day without a stop of its own).
    public var placeIndices: [Int]
    /// The legs arriving this day, into `PlaybackPlan.legs`.
    public var legs: Range<Int>
    /// The day's own stops, into `PlaybackPlan.stops`.
    public var stops: [Int]
    /// Where the day ends: its last stop, or where it holds (the last stop of an earlier day; the
    /// first stop before the route begins). `nil` only for a trip without stops.
    public var lastStop: Int?
    /// When its legs are done and it holds at `lastStop` (its start for a day without legs).
    public var holdStart: Double
    /// The place the day is about at its end ("Tag 3 von 9 · Vík"): `lastStop`'s.
    public var placeIndex: Int?

    public init(index: Int, day: LocalDay, start: Double, end: Double, photoCount: Int, placeIndices: [Int], legs: Range<Int>, stops: [Int],
                lastStop: Int?, holdStart: Double, placeIndex: Int?) {
        self.index = index
        self.day = day
        self.start = start
        self.end = end
        self.photoCount = photoCount
        self.placeIndices = placeIndices
        self.legs = legs
        self.stops = stops
        self.lastStop = lastStop
        self.holdStart = holdStart
        self.placeIndex = placeIndex
    }

    public var duration: Double { end - start }
    /// Whether the day has photos on the map or a stop of its own.
    public var hasPhotos: Bool { photoCount > 0 || !stops.isEmpty }
}

/// A point of the route the dot passes: a visit to a place of the trip.
public struct PlaybackStop: Hashable, Sendable {
    public var coordinate: GeoCoordinate
    /// Into `TripGeometry.places`.
    public var placeIndex: Int
    /// The day the dot arrives there.
    public var dayIndex: Int
    /// The camera's distance while the dot rests there.
    public var cameraMeters: Double

    public init(coordinate: GeoCoordinate, placeIndex: Int, dayIndex: Int, cameraMeters: Double) {
        self.coordinate = coordinate
        self.placeIndex = placeIndex
        self.dayIndex = dayIndex
        self.cameraMeters = cameraMeters
    }
}

/// The straight line (great circle) from one stop to the next, and when the dot goes along it.
public struct PlaybackLeg: Hashable, Sendable {
    /// Into `PlaybackPlan.stops`.
    public var from: Int
    public var to: Int
    /// The day it belongs to: the day of its arrival.
    public var dayIndex: Int
    public var start: Double
    public var end: Double
    /// Great-circle length.
    public var meters: Double
    /// The direction of travel, degrees clockwise from north (at the leg's middle).
    public var bearing: Double
    /// The trip's leg "ohne Fotos" (`RouteLeg.withoutPhotos`).
    public var withoutPhotos: Bool

    public init(from: Int, to: Int, dayIndex: Int, start: Double, end: Double, meters: Double, bearing: Double, withoutPhotos: Bool) {
        self.from = from
        self.to = to
        self.dayIndex = dayIndex
        self.start = start
        self.end = end
        self.meters = meters
        self.bearing = bearing
        self.withoutPhotos = withoutPhotos
    }
}

/// Where the camera is, as `MKMapCamera(lookingAtCenter:fromDistance:pitch:heading:)` takes it.
public struct PlaybackCamera: Hashable, Sendable {
    /// The point looked at: the dot.
    public var center: GeoCoordinate
    /// Metres from the camera to `center`.
    public var distanceMeters: Double
    /// Degrees from looking straight down.
    public var pitchDegrees: Double
    /// Degrees clockwise from north the camera faces: the direction of travel, so it looks from
    /// behind.
    public var headingDegrees: Double

    public init(center: GeoCoordinate, distanceMeters: Double, pitchDegrees: Double, headingDegrees: Double) {
        self.center = center
        self.distanceMeters = distanceMeters
        self.pitchDegrees = pitchDegrees
        self.headingDegrees = headingDegrees
    }
}

/// Everything at one moment of the playback (`PlaybackPlan.frame(at:)`).
public struct PlaybackFrame: Hashable, Sendable {
    public var time: Double
    public var dayIndex: Int
    /// How far into its day, 0 to 1.
    public var dayProgress: Double
    /// The dot.
    public var position: GeoCoordinate
    public var camera: PlaybackCamera
    /// The leg the dot moves along; `nil` while it rests at a stop.
    public var legIndex: Int?
    /// The stops reached (the dot passed them or rests at the last of them); at least 1 when the
    /// trip has stops.
    public var reachedStops: Int
    /// The place the dot is at (resting, or just leaving or arriving): its photos show beside it.
    /// `nil` on the way.
    public var placeIndex: Int?
    /// The place the day's title names now: the one the dot is at or heads to.
    public var titlePlaceIndex: Int?

    public init(time: Double, dayIndex: Int, dayProgress: Double, position: GeoCoordinate, camera: PlaybackCamera, legIndex: Int?,
                reachedStops: Int, placeIndex: Int?, titlePlaceIndex: Int?) {
        self.time = time
        self.dayIndex = dayIndex
        self.dayProgress = dayProgress
        self.position = position
        self.camera = camera
        self.legIndex = legIndex
        self.reachedStops = reachedStops
        self.placeIndex = placeIndex
        self.titlePlaceIndex = titlePlaceIndex
    }
}

/// The route's lines at a moment (`PlaybackPlan.route(for:)`).
public struct PlaybackRoute: Hashable, Sendable {
    /// The stops reached, in order: drawn solid white with a dark border (fewer than 2: none).
    public var travelled: [GeoCoordinate]
    /// From the last stop reached to the next one: drawn dashed (empty at the end).
    public var ahead: [GeoCoordinate]

    public init(travelled: [GeoCoordinate], ahead: [GeoCoordinate]) {
        self.travelled = travelled
        self.ahead = ahead
    }
}
