import Foundation
import Testing
@testable import AlbumistCore
@testable import AlbumistMap

/// Trips for the playback's tests: a route through given points on given days, built as
/// `TripGeometry.build` would leave it (one place per point, the route in order, the photos of
/// each day counted), without photo facts.
enum PlaybackFixture {
    static let firstDay = LocalDay(year: 2023, month: 6, day: 10)

    static func at(_ latitude: Double, _ longitude: Double) -> GeoCoordinate { GeoCoordinate(latitude: latitude, longitude: longitude) }

    /// A trip from `firstDay` over `days` days (at least up to the last point's day) whose route
    /// visits `points` (a coordinate and the day offset from `firstDay`) in order; each point is
    /// its own place "Ort 1", "Ort 2", ... with 10 photos. `extraPhotos` adds photos on days
    /// (offset: count), say for a day with photos but no new place.
    static func geometry(_ points: [(GeoCoordinate, Int)], days: Int? = nil, extraPhotos: [Int: Int] = [:]) -> TripGeometry {
        var places: [TripPlace] = []
        var route: [RoutePoint] = []
        var photos: [Int: Int] = extraPhotos
        for (i, point) in points.enumerated() {
            let day = LocalDay(dayNumber: firstDay.dayNumber + point.1)
            places.append(TripPlace(coordinate: point.0, name: "Ort \(i + 1)", countryKey: "IS", photoCount: 10, days: [day],
                                    coverCandidates: [AssetID("photo-\(i)")]))
            let arrival = Date(timeIntervalSince1970: Double(day.dayNumber) * 86_400 + Double(9 + i % 10) * 3_600)
            route.append(RoutePoint(placeIndex: i, arrival: arrival, departure: arrival.addingTimeInterval(1_800), day: day))
            photos[point.1, default: 0] += 10
        }
        let legs = zip(points, points.dropFirst()).map { RouteLeg(meters: GeoMath.distance($0.0, $1.0), withoutPhotos: false) }
        let lastOffset = max((days ?? 1) - 1, points.map(\.1).max() ?? 0)
        let dayCounts = photos.keys.sorted().map { TripDay(day: LocalDay(dayNumber: firstDay.dayNumber + $0), photoCount: photos[$0] ?? 0, placeIndex: nil) }
        let start = Date(timeIntervalSince1970: Double(firstDay.dayNumber) * 86_400)
        return TripGeometry(id: AlbumistID("playback-test"), start: start, end: start.addingTimeInterval(Double(lastOffset + 1) * 86_400),
                            timeZoneIdentifier: "UTC", firstDay: firstDay, lastDay: LocalDay(dayNumber: firstDay.dayNumber + lastOffset),
                            photoCount: photos.values.reduce(0, +), dayCounts: dayCounts, dayPlaces: [], places: places, route: route, legs: legs,
                            destinationIndex: places.isEmpty ? nil : 0, destination: points.first?.0 ?? at(64, -19), countryPhotos: [:],
                            mainCountryKey: nil, airborneCount: 0)
    }

    /// The circular difference of two headings in degrees (0 to 180).
    static func turn(_ a: Double, _ b: Double) -> Double { abs(PlaybackGeometry.signedDifference(from: a, to: b)) }
}

/// "Reise abspielen" worked out ahead (`PlaybackPlan`): days and their times, the dot on the
/// route, the drone camera, and the lookups between times and days.
@Suite("Playback plan")
struct PlaybackPlanTests {
    @Test func theDemoTripPlaysItsNineDaysInAMinute() {
        let plan = PlaybackPlan(trip: DemoTrip.iceland())
        #expect(plan.days.count == 9)
        #expect(plan.stops.count == 17 && plan.legs.count == 16)
        #expect(plan.days.first?.start == 0 && plan.duration <= PlaybackPlan.maximumSeconds)
        for (i, day) in plan.days.enumerated() {
            #expect(day.index == i)
            #expect(day.duration >= PlaybackPlan.shortestDaySeconds - 1e-9 && day.duration <= PlaybackPlan.longestDaySeconds + 1e-9)
            if i > 0 { #expect(day.start == plan.days[i - 1].end) }
        }
        #expect(plan.days.last?.end == plan.duration)
        // Day 3 (index 2): Seljalandsfoss, Skógafoss, Vík in route order, three legs, then the hold at Vík.
        let third = plan.days[2]
        #expect(third.placeIndices == [4, 5, 6] && third.legs.count == 3 && third.placeIndex == 6)
        #expect(abs(third.duration - 6.5) < 1e-9 && abs(third.holdStart - (third.start + 6.5 * 0.75)) < 1e-9)
        #expect(third.day == LocalDay(year: 2023, month: 6, day: 12) && third.photoCount == 99)
        // The first day has no leg: it holds at Reykjavík.
        #expect(plan.days[0].legs.isEmpty && plan.days[0].placeIndex == 0 && plan.days[0].duration == PlaybackPlan.shortestDaySeconds)
        // Each leg belongs to the day it arrives on and lies within it, in time order.
        for leg in plan.legs {
            let day = plan.days[leg.dayIndex]
            #expect(leg.start >= day.start - 1e-9 && leg.end <= day.holdStart + 1e-9 && leg.end > leg.start)
            #expect(plan.stops[leg.to].dayIndex == leg.dayIndex)
        }
        #expect(zip(plan.legs, plan.legs.dropFirst()).allSatisfy { $0.end <= $1.start + 1e-9 })
        #expect(plan.legs.filter(\.withoutPhotos).count == 4)
    }

    @Test func aDayWithoutPhotosHoldsTheLastPlaceBriefly() {
        let geometry = PlaybackFixture.geometry([(PlaybackFixture.at(64.15, -21.94), 0), (PlaybackFixture.at(64.26, -21.13), 2)])
        let plan = PlaybackPlan(geometry: geometry)
        #expect(plan.days.count == 3)
        #expect(abs(plan.days[1].duration - PlaybackPlan.emptyDaySeconds) < 1e-9 && !plan.days[1].hasPhotos)
        #expect(plan.days[1].placeIndices.isEmpty && plan.days[1].lastStop == 0 && plan.days[1].placeIndex == 0)
        // The leg belongs to the day it arrives on (the third); the empty day rests where the first ended.
        #expect(plan.legs.map(\.dayIndex) == [2])
        for share in [0.0, 0.3, 0.99] {
            let frame = plan.frame(at: plan.days[1].start + share * plan.days[1].duration)
            #expect(frame.dayIndex == 1 && frame.position == plan.stops[0].coordinate && frame.legIndex == nil && frame.placeIndex == 0)
        }
        // A day with photos but no new place holds for the shortest day.
        let stay = PlaybackPlan(geometry: PlaybackFixture.geometry([(PlaybackFixture.at(64.15, -21.94), 0), (PlaybackFixture.at(64.26, -21.13), 2)],
                                                                   extraPhotos: [1: 12]))
        #expect(abs(stay.days[1].duration - PlaybackPlan.shortestDaySeconds) < 1e-9 && stay.days[1].hasPhotos && stay.days[1].photoCount == 12)
    }

    @Test func aTripOfOnePlaceHoldsThereEveryDay() {
        let place = PlaybackFixture.at(63.5321, -19.5114)
        let plan = PlaybackPlan(geometry: PlaybackFixture.geometry([(place, 0)], days: 3, extraPhotos: [1: 20, 2: 5]))
        #expect(plan.days.count == 3 && plan.stops.count == 1 && plan.legs.isEmpty && plan.turns.isEmpty)
        #expect(abs(plan.duration - 3 * PlaybackPlan.shortestDaySeconds) < 1e-9)
        for time in stride(from: 0.0, through: plan.duration, by: 0.37) {
            let frame = plan.frame(at: time)
            #expect(frame.position == place && frame.camera.center == place && frame.placeIndex == 0 && frame.titlePlaceIndex == 0)
            #expect(frame.camera.distanceMeters == PlaybackPlan.holdCameraMeters && frame.camera.headingDegrees == 0)
            #expect(frame.camera.pitchDegrees >= 55 && frame.camera.pitchDegrees <= 65)
            #expect(frame.reachedStops == 1)
        }
        #expect(plan.route(for: plan.frame(at: 1)) == PlaybackRoute(travelled: [place], ahead: []))
    }

    @Test func aTripWithoutAPlaceHoldsAtItsDestination() {
        var geometry = PlaybackFixture.geometry([], days: 2)
        geometry.destination = PlaybackFixture.at(-18.12, 178.45)
        let plan = PlaybackPlan(geometry: geometry)
        #expect(plan.stops.isEmpty && plan.days.count == 2 && abs(plan.duration - 2 * PlaybackPlan.emptyDaySeconds) < 1e-9)
        let frame = plan.frame(at: 1.5)
        #expect(frame.position == geometry.destination && frame.placeIndex == nil && frame.titlePlaceIndex == nil && frame.reachedStops == 0)
        #expect(plan.route(for: frame) == PlaybackRoute(travelled: [], ahead: []))
        // A destination that is no number: 0, 0 rather than a broken camera.
        geometry.destination = PlaybackFixture.at(.nan, 3)
        #expect(PlaybackPlan(geometry: geometry).frame(at: 0).camera.center == PlaybackFixture.at(0, 0))
    }

    @Test func aLongTripStillPlaysInAMinute() {
        let sixty = (0..<60).map { (PlaybackFixture.at(45 + Double($0) * 0.05, 7 + Double($0 % 7) * 0.1), $0) }
        let plan = PlaybackPlan(geometry: PlaybackFixture.geometry(sixty))
        #expect(plan.days.count == 60 && plan.duration <= PlaybackPlan.maximumSeconds + 1e-9)
        #expect(abs(plan.duration - PlaybackPlan.maximumSeconds) < 1e-9)
        #expect(plan.days.allSatisfy { $0.duration > 0 })
        #expect(plan.days.last?.end == plan.duration)
        // Days of very different lengths are shortened alike.
        let ratio = plan.days[1].duration / plan.days[0].duration
        #expect(abs(ratio - 3.5 / 3.0) < 1e-9)
        // A broken date range: at most `maximumDays` segments; a last day before the first: one.
        var broken = PlaybackFixture.geometry([(PlaybackFixture.at(64, -19), 0)])
        broken.lastDay = LocalDay(year: 2150, month: 1, day: 1)
        let long = PlaybackPlan(geometry: broken)
        #expect(long.days.count == PlaybackPlan.maximumDays && long.duration <= PlaybackPlan.maximumSeconds + 1e-9)
        broken.lastDay = LocalDay(year: 2001, month: 1, day: 1)
        #expect(PlaybackPlan(geometry: broken).days.count == 1)
    }

    @Test func theDotMovesAlongTheLegsEased() {
        let a = PlaybackFixture.at(64.0, -20.0), b = PlaybackFixture.at(64.0, -19.0)
        let plan = PlaybackPlan(geometry: PlaybackFixture.geometry([(a, 0), (b, 1)]))
        let leg = plan.legs[0]
        #expect(plan.frame(at: leg.start).position == a && plan.frame(at: leg.end).position == b)
        let middle = plan.frame(at: (leg.start + leg.end) / 2)
        // Half way along the great circle (a little north of the parallel), on the leg.
        #expect(abs(GeoMath.distance(a, middle.position) - GeoMath.distance(middle.position, b)) < 1)
        #expect(middle.position.latitude > 64 && middle.legIndex == 0 && middle.placeIndex == nil && middle.titlePlaceIndex == 1)
        // Slow at the ends, fast in the middle.
        let step = (leg.end - leg.start) / 100
        let atStart = GeoMath.distance(plan.frame(at: leg.start).position, plan.frame(at: leg.start + step).position)
        let inMiddle = GeoMath.distance(plan.frame(at: (leg.start + leg.end) / 2).position, plan.frame(at: (leg.start + leg.end) / 2 + step).position)
        #expect(atStart * 30 < inMiddle)
        // Leaving and arriving, the dot is at a place (its photos show); the title names the destination.
        #expect(plan.frame(at: leg.start + step).placeIndex == 0 && plan.frame(at: leg.start + step).titlePlaceIndex == 0)
        #expect(plan.frame(at: leg.end - step).placeIndex == 1)
    }

    @Test func theCameraLooksFromBehindAndAbove() {
        let plan = PlaybackPlan(trip: DemoTrip.iceland())
        for leg in plan.legs {
            // Outside the turns the camera faces the direction of travel.
            let middle = plan.frame(at: (leg.start + leg.end) / 2)
            #expect(PlaybackFixture.turn(middle.camera.headingDegrees, leg.bearing) < 1e-6)
            #expect(middle.camera.center == middle.position)
            #expect(middle.camera.pitchDegrees >= 55 && middle.camera.pitchDegrees <= 65)
            #expect(middle.camera.distanceMeters >= 2_000 && middle.camera.distanceMeters <= 60_000)
        }
        // The camera's distance follows the legs: the short hop from Geysir to Gullfoss comes
        // close, the long drive from Akureyri to Borgarnes stays far.
        let hop = plan.frame(at: (plan.legs[2].start + plan.legs[2].end) / 2).camera.distanceMeters
        let drive = plan.frame(at: (plan.legs[14].start + plan.legs[14].end) / 2).camera.distanceMeters
        #expect(hop < 20_000 && drive > 40_000)
        #expect(PlaybackPlan.pitch(forDistance: 2_000) == 65 && PlaybackPlan.pitch(forDistance: 60_000) == 55)
        #expect(PlaybackPlan.pitch(forDistance: 1) == 65 && PlaybackPlan.pitch(forDistance: 1e9) == 55 && PlaybackPlan.pitch(forDistance: .nan) == 55)
    }

    @Test func everythingIsContinuousAtLegAndDayBoundaries() {
        let plan = PlaybackPlan(trip: DemoTrip.iceland())
        let boundaries = plan.legs.flatMap { [$0.start, $0.end] } + plan.days.map(\.start) + plan.days.map(\.holdStart)
        for time in boundaries where time > 1e-6 && time < plan.duration - 1e-6 {
            let before = plan.frame(at: time - 1e-7), after = plan.frame(at: time + 1e-7)
            #expect(GeoMath.distance(before.position, after.position) < 0.5, "\(time)")
            #expect(abs(before.camera.distanceMeters - after.camera.distanceMeters) < 1, "\(time)")
            #expect(abs(before.camera.pitchDegrees - after.camera.pitchDegrees) < 1e-3, "\(time)")
            #expect(PlaybackFixture.turn(before.camera.headingDegrees, after.camera.headingDegrees) < 0.01, "\(time)")
        }
        // And between any two frames of a 120 Hz display: no jump, no wild spin.
        var previous = plan.frame(at: 0)
        var fastest = 0.0
        for step in 1...Int(plan.duration * 120) {
            let frame = plan.frame(at: Double(step) / 120)
            #expect(GeoMath.distance(previous.position, frame.position) < 2_000)
            fastest = max(fastest, PlaybackFixture.turn(previous.camera.headingDegrees, frame.camera.headingDegrees) * 120)
            previous = frame
        }
        #expect(fastest < 1.6 * PlaybackPlan.turnDegreesPerSecond)
    }

    @Test func theHeadingTurnsTheShortWayRound() {
        // North with a touch of west (359°), then north with a touch of east (1°).
        let plan = PlaybackPlan(geometry: PlaybackFixture.geometry([(PlaybackFixture.at(0, 0), 0), (PlaybackFixture.at(1, -0.01745), 1),
                                                                    (PlaybackFixture.at(2, 0), 2)]))
        #expect(abs(PlaybackFixture.turn(plan.legs[0].bearing, 359)) < 0.05 && abs(PlaybackFixture.turn(plan.legs[1].bearing, 1)) < 0.05)
        #expect(plan.turns.count == 1 && plan.turns[0].change > 0 && plan.turns[0].change < 2.1)
        for time in stride(from: 0.0, through: plan.duration, by: 0.01) {
            let heading = plan.frame(at: time).camera.headingDegrees
            #expect(heading >= 0 && heading < 360)
            #expect(PlaybackFixture.turn(heading, 0) <= 1.05, "\(time) \(heading)")
        }
        // The helpers: the short way round, in (−180, 180].
        #expect(PlaybackGeometry.signedDifference(from: 359, to: 1) == 2)
        #expect(PlaybackGeometry.signedDifference(from: 1, to: 359) == -2)
        #expect(PlaybackGeometry.signedDifference(from: 0, to: 180) == 180)
        #expect(PlaybackGeometry.signedDifference(from: 90, to: -90) == 180)
        #expect(PlaybackGeometry.normalizedDegrees(-1) == 359 && PlaybackGeometry.normalizedDegrees(720) == 0)
        #expect(PlaybackGeometry.normalizedDegrees(.nan) == 0)
        // A U-turn takes its time: at most `turnDegreesPerSecond` where the legs allow it.
        let back = PlaybackPlan(geometry: PlaybackFixture.geometry([(PlaybackFixture.at(64, -20), 0), (PlaybackFixture.at(64, -19), 1),
                                                                    (PlaybackFixture.at(64, -20), 2)]))
        let uTurn = back.turns[0]
        #expect(abs(abs(uTurn.change) - 180) < 1 && uTurn.end - uTurn.start >= 180 / PlaybackPlan.turnDegreesPerSecond - 1e-9)
    }

    @Test func aTripAcrossTheAntimeridian() {
        let fiji = PlaybackFixture.at(-18.1248, 178.4501), samoa = PlaybackFixture.at(-13.8333, -171.7667)
        let plan = PlaybackPlan(geometry: PlaybackFixture.geometry([(fiji, 0), (samoa, 1), (fiji, 3)]))
        #expect(plan.legs.count == 2)
        // About 1,150 km, heading east-north-east, then back west-south-west.
        #expect(plan.legs[0].meters > 1_000_000 && plan.legs[0].meters < 1_300_000)
        #expect(plan.legs[0].bearing > 45 && plan.legs[0].bearing < 90 && plan.legs[1].bearing > 225 && plan.legs[1].bearing < 270)
        for leg in plan.legs {
            for share in stride(from: 0.0, through: 1.0, by: 0.05) {
                let frame = plan.frame(at: leg.start + share * (leg.end - leg.start))
                // Along the short way over the date line, never round through Greenwich.
                #expect(abs(frame.position.longitude) >= 171, "\(frame.position)")
                #expect(frame.position.longitude >= -180 && frame.position.longitude < 180)
                #expect(frame.position.latitude > -18.2 && frame.position.latitude < -13.7)
            }
        }
        let route = plan.route(for: plan.frame(at: plan.legs[0].start + 0.1))
        #expect(route.travelled == [fiji] && route.ahead == [fiji, samoa])
        // A local day that steps back across the date line still plays forward.
        let back = PlaybackPlan(geometry: PlaybackFixture.geometry([(samoa, 1), (fiji, 0)]))
        #expect(back.stops.map(\.dayIndex) == [1, 1] && back.legs.map(\.dayIndex) == [1])
    }

    @Test func theRouteGrowsStopByStop() {
        let plan = PlaybackPlan(trip: DemoTrip.iceland())
        #expect(plan.route(for: plan.frame(at: 0)) == PlaybackRoute(travelled: [plan.stops[0].coordinate],
                                                                   ahead: [plan.stops[0].coordinate, plan.stops[1].coordinate]))
        for (l, leg) in plan.legs.enumerated() {
            let on = plan.frame(at: (leg.start + leg.end) / 2)
            #expect(on.legIndex == l && on.reachedStops == leg.from + 1)
            let route = plan.route(for: on)
            #expect(route.travelled == plan.stops.prefix(leg.from + 1).map(\.coordinate))
            #expect(route.ahead == [plan.stops[leg.from].coordinate, plan.stops[leg.to].coordinate])
            #expect(plan.frame(at: leg.end).reachedStops == leg.to + 1)
        }
        let end = plan.frame(at: plan.duration)
        #expect(end.reachedStops == plan.stops.count && plan.route(for: end).ahead.isEmpty)
        #expect(end.titlePlaceIndex == 16 && end.dayIndex == 8 && end.dayProgress == 1)
    }

    @Test func timesAndDaysLookEachOtherUp() {
        let plan = PlaybackPlan(trip: DemoTrip.iceland())
        for (i, day) in plan.days.enumerated() {
            #expect(plan.startTime(ofDay: i) == day.start)
            #expect(plan.dayIndex(at: day.start) == i)
            #expect(plan.dayIndex(at: (day.start + day.end) / 2) == i)
            if i > 0 { #expect(plan.dayIndex(at: day.start - 1e-9) == i - 1) }
            #expect(plan.frame(at: day.start).dayIndex == i && plan.frame(at: day.start).dayProgress == 0)
            #expect(plan.dayIndex(atFraction: plan.fraction(at: (day.start + day.end) / 2)) == i)
        }
        #expect(plan.dayIndex(at: -5) == 0 && plan.dayIndex(at: plan.duration + 5) == 8 && plan.dayIndex(at: .nan) == 0)
        #expect(plan.startTime(ofDay: -1) == 0 && plan.startTime(ofDay: 99) == plan.days[8].start)
        #expect(plan.dayIndex(atFraction: 0) == 0 && plan.dayIndex(atFraction: 1) == 8 && plan.dayIndex(atFraction: 7) == 8)
        #expect(plan.dayIndex(atFraction: -1) == 0 && plan.dayIndex(atFraction: .nan) == 0)
        #expect(plan.fraction(at: plan.duration / 2) == 0.5 && plan.fraction(at: -1) == 0 && plan.fraction(at: .infinity) == 1)
        // A frame for a time out of range is the start's or the end's.
        #expect(plan.frame(at: -3) == plan.frame(at: 0) && plan.frame(at: 1e9) == plan.frame(at: plan.duration))
        #expect(plan.frame(at: .nan) == plan.frame(at: 0))
    }

    @Test func thePlanIsTheSameEveryTime() {
        #expect(PlaybackPlan(trip: DemoTrip.iceland()) == PlaybackPlan(trip: DemoTrip.iceland()))
    }
}
