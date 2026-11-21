import Foundation
import AlbumistCore

/// Photos taken in flight (concept §5, "Flugzeugfotos zählen nicht"): they make no place, no
/// country and no record. Without this, three window photos over France on the way to Lisbon
/// would make France a visited country and a place in the clouds. The map counts only photos on
/// the ground (`FlightJudgement`, `judge`): besides those the rules below find, none maybe taken
/// in flight (one flown leg and no stay), so the window photos the rules miss (listed below)
/// count for nothing either.
///
/// Until the analysis stores altitudes, the photos' places and times decide: nothing on the ground
/// moves faster than `maximumGroundSpeed`, and a plane flies straight on. A photo's two **legs** go
/// to its nearest photo before and its nearest photo after it that are at least `minimumLegMeters`
/// away and at most `maximumLongLegDuration` apart in time; a leg was **flown** when it is faster
/// than `maximumGroundSpeed` and not faster than `maximumFlightSpeed`. A photo counts as taken in
/// flight when
/// 1. the iPhone stored an altitude above `maximumAltitude` for it; or, as long as the location
///    does not **come back** to it (`returnDuration`: no photo one to five minutes before or after
///    it lies within `minimumLegMeters`),
/// 2. **it lies on a run:** both its legs were flown, it lies on the way between them, it shows no
///    stay (`FlightTrack.stays`), no leg of at most `runEndLongDuration` leads to a photo that
///    stays (`FlightTrack.staysAt`), and the run does not turn back right before or after it (a
///    leg faster than `turnBackSpeed` that leaves the way); or
/// 3. **it is in a burst:** `burstPhotos` photos in a row, each at most `burstStepDuration` and at
///    least `burstStepMeters` after the one before, that move steadily (speeds above `burstSpeed`,
///    or above `aloftBurstSpeed` from one photo with a stored altitude above `aloftAltitude` to
///    another, not faster than a plane, within `burstSpeedRatio` of each other) and straight on
///    (`burstStraightness`), make a burst; bursts sharing a photo are one. It counts when it holds
///    four such photos in a row (steady and straight over all four), or else when it **heads on**
///    (`FlightTrack.headsOn`): it has a leg (the leg before its first photo or the leg after its
///    last), its way from its first photo to its last takes it away from the photo before and
///    towards the photo after by at least `burstHeading` of that way's length, and it shows no
///    stay of `stayDuration` (a minute of photos within `minimumLegMeters` of its first photo
///    before it, or of its last after it); or
/// 4. **it ends a run:** one of its legs leads to a photo of rules 1 to 3, was flown and takes at
///    most `runEndDuration` (or `runEndLongDuration` when faster than `runEndLongSpeed`), the photo
///    lies on the way between its legs, the run goes on in a line beyond that photo, and the photo
///    shows no stay.
///
/// What each part is for, and what keeps the ground on the ground:
/// - Rule 2 finds the window photos in the middle of a flight. Long legs find those of a long-haul
///   flight with a photo every few hours, or a burst over Siberia five hours after the gate photo.
///   A leg faster than `maximumFlightSpeed` is evidence of nothing (two people's photos from Munich
///   and Rome in the same minutes, a wrong location); a photo out of reach (`jumpMeters`) is no
///   neighbour at all. A **stay**: the photos in a row within `minimumLegMeters` around the
///   photo, lasting at least `shortestStay`, did not move on along its legs faster than
///   `maximumGroundSpeed` over their time (nor further than their stated accuracy). In a plane
///   such a row lasts well under a minute and moves on at the plane's speed, so a stay is ground
///   (or a location the iPhone failed to update): a layover of three photos over half an hour at
///   Dubai between Munich and Bangkok stays on the ground, and so does a quick series of photos
///   there, or at Vienna between Berlin and Athens, an hour or two from either. **A single photo
///   shows no stay,** nor do photos within `shortestStay` (the iPhone updates the location about
///   once a second, so the fixes of a plane's photos seconds apart may be up to a second's flight
///   behind them): one photo at a layover between two flown legs counts as in flight, and so do
///   photos there within five seconds. One such photo costs no place and no record (both need
///   three photos within 3 km on one day) and no country unless that country's only photos are
///   such layover photos; but its town is missing from the cities when it has no other photo.
///   Three within five seconds can cost a place.
/// - A **short leg to a stay** is no flight leg, for the reason of rule 4 below: a plane needs at
///   least a quarter of an hour from standing on the ground to an average above
///   `maximumGroundSpeed` (and back). It keeps out a location jumping 3 km to one side and 3 km to
///   the other within seconds indoors, between minutes of photos near either end.
/// - The **turn back** check: two people's photos from Munich, Florence and Rome alternating every
///   half hour (an iCloud Shared Library) look like flights Munich → Florence → Rome, but then
///   "fly" straight back to Munich. A real flight goes on, or its next leg is slow.
/// - A photo **out of reach** (`jumpMeters`) is someone else's and nobody's neighbour: in a shared
///   library the window photos between the photos someone takes at home are found as if those
///   were not there. Within reach of them (near the airport of home) they can still zig-zag.
/// - **Coming back** keeps out a location landing 1 to 3 km off in any direction every few seconds
///   indoors: now and then three of its photos happen to lie in a line at a plane's speed, but
///   within minutes the location is back near each of them. A plane is gone.
/// - Rule 3 finds window photos seconds apart with no photo near enough in time for a leg: three
///   photos over France on the way to Lisbon with the gate photo hours before, or a short flight
///   with one series over the Alps. GPS errors seldom make a series of four: a location jumping
///   away comes back (not straight on), a first coarse fix closing in on the true place takes ever
///   shorter steps (not steady), a drift indoors is slow; only a fix sliding along steadily does,
///   as one catching up after a tunnel. A step shorter than the stated accuracy of its two fixes
///   is no step. Two steady steps are not enough on their own: a fix closing in can make them,
///   and so can a location jumping 1 to 3 km three times in a row by chance. So a burst of three
///   must also head on, as a plane flies on from where the photos before it were taken towards
///   where the photos after it will be. A GPS error has no heading of its own: between two photos
///   at home it cannot head away from home and towards it at once, and a minute of photos near it
///   is a stay. `burstSpeed` keeps the fastest trains out with their GPS noise. Above
///   `aloftAltitude` nothing on the ground moves at `aloftBurstSpeed` (see there), so with stored
///   altitudes a burst up there needs only that: three photos in the climb at 3,500 m and
///   350 km/h make no "Höchstes Foto", while summits up to 5,895 m, cable cars and mountain
///   railways keep theirs.
/// - Rule 4 finds the first and last window photo of a flight: their other leg goes to the gate
///   photo half an hour before take-off or the arrival photo after landing and is slow. Physical
///   reason it never takes a photo outside the plane: such a photo is taken at least five minutes
///   before the brakes are released for take-off (boarding, doors, taxiing) or after the plane has
///   stopped, and an airliner covers about 30 km in its first five minutes in the air and about
///   80 km (100 with a tailwind) in its first ten. So within `runEndDuration` a photo outside the
///   plane is never 400 km/h × 10 min = 67 km from one in the air, nor within `runEndLongDuration`
///   500 km/h × 15 min = 125 km. (A photo in the plane on the runway may be; it is harmless.)
///   The leg must lead to a confirmed run, because one fast leg proves nothing: a wrong location
///   30 km away a minute after a photo makes one, and "on the way" decides nothing when one leg is
///   ten times the other (3 km back and 30 km on passes `detourFactor` in any direction).
///
/// Window photos it misses (once the analysis stores altitudes, rule 1 catches those taken above
/// `maximumAltitude`): a flight with fewer than three window photos, unless its legs to the ground
/// are flown (a short hop with two photos); the first or last window photo more than
/// `runEndDuration` (`runEndLongDuration`) before or after the next one (a long-haul flight with a
/// photo every few hours, unless its leg to the airport is flown), or off the way (a turn after
/// take-off); window photos next to photos someone else took within reach of them (in a shared
/// library, at home near the airport); photos whose location the iPhone did not update in the
/// plane for `shortestStay` and more (they look like a stay); a burst of three that does not head
/// on (in a turn, on a route far off the line between the photos before and after it, or with no
/// photo within `maximumLongLegDuration` on either side); a series whose steps the age of its
/// fixes makes uneven (a fix a second old on a step of a second or two); a burst during the climb
/// or descent slower than `burstSpeed` (with stored altitudes: below `aloftAltitude` or slower
/// than `aloftBurstSpeed`), unless rule 4 takes it; photos of a plane circling back within 3 km in
/// five minutes (a holding pattern).
///
/// Ground photos it can take for window photos: three photos within seconds whose location jumps
/// 3 km and more in a straight line at a plane's speed with no photo near either end and none
/// coming back; three whose location slides like that along the way from the photos before them
/// to those after them, and four that slide like that anywhere (rule 3: a coarse fix closing in,
/// or a fix catching up after a tunnel on a fast train, stating no accuracy; above
/// `aloftAltitude`, with stored altitudes, a slide at `aloftBurstSpeed` is enough, as on a
/// mountain railway); one photo at a layover between two flown legs (or photos there within
/// `shortestStay`, or a few seconds of photos whose location jumps on along the route); one photo
/// half an hour from a place on the line between two others, once (Munich, Florence, Rome); the
/// odd photo of a location scattered further than 3 km within seconds.
public enum AirborneFilter {
    /// Above this a photo was taken in a plane (concept §5: "Fotos über 6.000 m Höhe"). Places
    /// people photograph on the ground stay below it (Kilimanjaro 5,895 m, the Everest base camp
    /// 5,364 m); the few higher summits are left out with the planes.
    public static let maximumAltitude = 6_000.0
    /// Faster than this from one photo to the next is no ground transport (concept §5:
    /// "schneller als ein Flugzeug am Boden"): high-speed trains run at up to 350 km/h in
    /// service, planes cruise at 800 to 900 km/h over the ground. 400 km/h, in metres per second.
    public static let maximumGroundSpeed = 400.0 / 3.6
    /// Faster than this from one photo to the next is no travel at all, not even by plane: the
    /// fastest airliner ground speeds with a strong jet stream reach about 1,300 km/h. Such a
    /// "leg" joins the photos of two people in one library (an iCloud Shared Library, Munich
    /// and Rome in the same minutes) or a wrong location, and is no evidence of a flight; a
    /// trip's route does not zig-zag along it either. 1,500 km/h, in metres per second.
    public static let maximumFlightSpeed = 1_500.0 / 3.6
    /// Shorter legs say nothing about speed: the GPS fixes of photos seconds apart jitter by some
    /// hundred metres, which looks like any speed. A neighbour is the nearest photo at least
    /// this far away (a burst of window photos seconds apart reaches past its own burst).
    public static let minimumLegMeters = 3_000.0
    /// A photo further from another than `maximumFlightSpeed` covers in the time between them, and
    /// more than this further, is **out of reach**: someone else's photo (an iCloud Shared Library:
    /// someone at home while the other flies) or a wrong location far off, and no photo's neighbour
    /// (`FlightTrack.neighbour`). Twice `minimumLegMeters`: a location jumping indoors lands up to
    /// that far off the true place (`returnDuration`), so two of one camera's fixes seconds apart
    /// can lie up to this far apart. Such a leg ends the search for a neighbour, as evidence of
    /// nothing: passed, the next jump 10 to 20 seconds away looked like a leg at a plane's speed.
    static let jumpMeters = 2 * minimumLegMeters
    /// The longest leg: the longest non-stop flights take some 19 hours from the gate photo to the
    /// arrival photo. It also bounds the search for a photo's neighbours.
    static let maximumLongLegDuration: TimeInterval = 20 * 3_600
    /// A stay this long counts against any leg. The photos of a row lie within `minimumLegMeters`
    /// of the photo, so within 6 km of each other: a plane at `maximumGroundSpeed` or faster leaves
    /// that behind in 54 seconds, so a row lasting a minute and more (with its location updated)
    /// is on the ground. It also bounds the search for a photo's neighbours to a minute of
    /// photos near it, however many photos a day at one place has.
    static let stayDuration: TimeInterval = 60
    /// A row of photos shows a stay by how little it moved on only when it lasts at least this
    /// (`FlightTrack.stays`). The iPhone updates the location about once a second, so the fixes of
    /// a plane's photos may be up to a second's flight behind them, which takes up to a second off
    /// a row: at 500 km/h, four seconds of flight cover what 400 km/h covers in five. (Slower in
    /// the climb, or with older fixes, a plane's row can look like a stay.)
    static let shortestStay: TimeInterval = 5
    /// A plane needs at least this long, on top of the time a leg takes at `maximumFlightSpeed`,
    /// to come down from flying to standing at the gate (approach, landing, taxiing in), or to get
    /// from the gate into the air (taxiing out, take-off): well over 20 minutes each. So a row of
    /// photos on one fix between two flown legs, under a minute on either side of the photo, is
    /// no stay (rule 2) where the leg before it leaves less time to land or the leg after it less
    /// time to take off: the plane was in the air, and the iPhone did not update the location
    /// for the row (a fix frozen for seconds in the cabin). The layovers stay: Berlin to Vienna
    /// in 72 minutes (525 km) leaves time, and so does Vienna to Athens (1,280 km) in an hour and a
    /// half. Only a row on one fix: photos whose fixes differ show by them how far they moved on,
    /// and between someone else's photos minutes away (an iCloud Shared Library) or a location
    /// jumping kilometres indoors, a row that did not move on is the ground.
    static let landingDuration: TimeInterval = 20 * 60
    /// The location **comes back** when a photo at least `stayDuration` and at most this long
    /// before or after a photo lies closer than `minimumLegMeters` to it. A plane at
    /// `maximumGroundSpeed` and more is 6.7 km on after a minute; to come back within 3 km (with
    /// 500 m of error on either fix) it has to turn through some 230°, which takes it more than 75
    /// seconds even in the tightest turn an airliner flies (30° of bank at 400 km/h, a circle of
    /// 4.4 km): only a plane circling (a holding pattern) comes back, and its photos are missed,
    /// never the ground's. A location jumping around indoors comes back again and again: within
    /// five minutes some of its photos land within 3 km of any one of them.
    static let returnDuration: TimeInterval = 5 * 60

    /// "On the way": both legs together at most this many times the direct way from the photo
    /// before to the photo after (brief: about 1.3). A plane's track bends far less between two
    /// photos (two equal legs pass up to a turn of 79°); a zig-zag goes there and back, twice
    /// the way over a direct way of almost nothing.
    static let detourFactor = 1.3
    /// ... plus this. On the shortest legs (3 km each) GPS errors alone can lengthen the two legs
    /// of a straight flight past 1.3 times the direct way; 2 km covers errors of about 600 m on
    /// each of the three photos there. A zig-zag has at least two legs of 3 km, 6 km over a direct
    /// way near nothing, and stays out.
    static let detourAllowanceMeters = 2_000.0
    /// Photos one after another within this of the first of them form a group, which the search
    /// for a photo's neighbours passes or takes with one distance instead of one per photo, so a
    /// long burst at one place costs no more than a single photo. A third of a leg: two photos
    /// of one group are at most 2 km apart, so no group holds a leg.
    static let groupRadiusMeters = minimumLegMeters / 3

    /// Rule 4: the leg from a run's end to the run takes at most this, ...
    static let runEndDuration: TimeInterval = 10 * 60
    /// ... or at most this when faster than `runEndLongSpeed` (window photos 15 minutes apart in
    /// climb or cruise are 650 km/h and more apart). See the type for why no photo outside the plane
    /// passes either.
    static let runEndLongDuration: TimeInterval = 15 * 60
    static let runEndLongSpeed = 500.0 / 3.6

    /// Rule 3: a burst has at least this many photos (two steps) ...
    static let burstPhotos = 3
    /// ... each at most this long after the one before ...
    static let burstStepDuration: TimeInterval = 60
    /// ... and at least this far from it (a plane covers 220 m and more a second; the jitter of a
    /// fix outdoors is tens of metres) ...
    static let burstStepMeters = 200.0
    /// ... faster than this: a plane at cruise flies 800 to 900 km/h, while a train at 350 km/h
    /// covers 194 m in two seconds and would need some 80 m of GPS noise in its direction on every
    /// step in a row to look like this ...
    static let burstSpeed = 500.0 / 3.6
    /// ... at speeds at most this factor apart ...
    static let burstSpeedRatio = 1.5
    /// ... along a path at most this many times the way from the first photo to the last (a turn of
    /// up to about 60° between steps).
    static let burstStraightness = 1.15
    /// A burst without four photos in a row that move steadily and straight on over all four
    /// (three such steps are evidence enough; two can be a coarse fix closing in) heads on when its
    /// way takes it away from the photo before it and towards the photo after it by at least this
    /// share of its length: roughly, it points no more than 60° off the line from the photo before
    /// it, and off the line to the photo after it. A flight's track keeps far closer to those but
    /// in turns near the airports; a location jumping around one place points any way.
    static let burstHeading = 0.5
    /// From one photo with a stored altitude above this to another, a burst's step needs only to
    /// be faster than `aloftBurstSpeed`. Up there nothing on the ground comes near it: the fastest
    /// railway, the Lanzhou–Xinjiang high-speed line over the Qilian mountains (3,600 m), is built
    /// for 250 km/h, the railways to Lhasa run at 160 km/h and less, cable cars at 45 km/h; an
    /// airliner climbs or descends through 3,000 m at well over 300 km/h. (A plane taking off from
    /// an airport that high may pass it on the runway; its photos are harmless.)
    static let aloftAltitude = 3_000.0
    static let aloftBurstSpeed = 300.0 / 3.6
    /// Next to a single flown leg (`FlightJudgement`), a row of photos shows a stay only when it
    /// moved on slower than this. An airliner leaves the runway at 250 to 300 km/h and flies its
    /// last minutes before landing at 250 to 350 km/h, slower than `maximumGroundSpeed`, so a
    /// series of window photos there looks like a stay by that measure. On the ground only trains
    /// run faster than this, and a train's photos have no flown leg. 200 km/h, in metres per
    /// second.
    static let stayMovingSpeed = 200.0 / 3.6
    /// A run **turns back** (rules 2 and `FlightJudgement`) on a leg faster than this right before
    /// or after it that leaves its way. A plane flies on; from the airport people go on by car or
    /// train, slower than this as the crow flies (the trip's route measures turning back by the same
    /// speed, `TripGeometryBuilder.turnBackSpeed`). Photos of two or three people taken in turn do
    /// not: Munich, Florence and Rome every 20 minutes look like a flight Munich → Florence →
    /// Rome, Munich next is out of reach, and Rome to Florence 40 minutes later is 345 km/h.
    /// 200 km/h, in metres per second.
    static let turnBackSpeed = 200.0 / 3.6

    /// The photos of `photos` taken in flight.
    /// - Parameters:
    ///   - photos: the whole library, in any order (a photo's neighbours are the photos taken
    ///     before and after it, whatever trip they belong to). Only photos with a usable location
    ///     and a date that are no screenshots are judged; the others are never in the result
    ///     and are nobody's neighbour.
    ///   - altitudes: metres above sea level the iPhone stored, by photo, where known.
    public static func airborne(_ photos: [AssetSnapshot], altitudes: [AssetID: Double] = [:]) -> Set<AssetID> {
        let track = FlightTrack(photos)
        let (high, aloft) = levels(of: track, altitudes)
        return track.ids(where: track.inFlight(high: high, aloft: aloft))
    }

    /// The photos of `photos` taken in flight and those maybe taken in flight: what the map does
    /// not count (`FlightJudgement`). Parameters as `airborne`.
    public static func judge(_ photos: [AssetSnapshot], altitudes: [AssetID: Double] = [:]) -> FlightJudgement {
        let track = FlightTrack(photos)
        let (high, aloft) = levels(of: track, altitudes)
        let judged = track.judge(high: high, aloft: aloft, maybe: true)
        let airborne = track.ids(where: judged.inFlight)
        // A library holding one id twice may have it judged both ways: in flight wins.
        return FlightJudgement(airborne: airborne, maybeInFlight: track.ids(where: judged.maybe).subtracting(airborne))
    }

    /// Per photo of `track`, whether its stored altitude is above `maximumAltitude` (rule 1) and
    /// whether above `aloftAltitude` (rule 3).
    static func levels(of track: FlightTrack, _ altitudes: [AssetID: Double]) -> (high: [Bool], aloft: [Bool]) {
        let stored: [Double?] = altitudes.isEmpty ? [] : track.ids.map { altitudes[$0] }
        func above(_ level: Double) -> [Bool] {
            stored.isEmpty ? [Bool](repeating: false, count: track.ids.count) : stored.map { $0.map { $0 > level } ?? false }
        }
        return (above(maximumAltitude), above(aloftAltitude))
    }
}

/// What the map makes of where and when the photos were taken: which were taken in flight and
/// which maybe were. All others are **on the ground**, and only those count: for a country, a
/// town, a trip's places, route and countries, and so for every record (concept §5:
/// "Flugzeugfotos zählen nicht"). This is the one definition the map counts by
/// (`MapCountries.compute`, `MapCountries.cityCount`, `TripGeometry.build`, `MapSummary.build`).
///
/// A judged photo (`AirborneFilter.airborne`: a usable location, a date, no screenshot) is on the
/// ground unless
/// - it was **taken in flight** (`airborne`): rules 1 to 4 of `AirborneFilter`; or
/// - it was **maybe taken in flight** (`maybeInFlight`): exactly one of its legs was flown (and is
///   no short leg to a stay, as in rule 2), and rule 2's conditions hold with that one leg: it
///   lies on the way where it has two legs, it shows no stay, the run does not turn back and the
///   location does not come back to it. Next to the flown leg, a row of photos shows a stay only
///   when it moved on slower than `AirborneFilter.stayMovingSpeed` (a plane in its first and last
///   minutes is slower than `maximumGroundSpeed`). With both legs flown, rule 2 has judged it:
///   a layover's stay is on the ground, as a zig-zag of two people's photos is.
/// A photo the filter does not judge (no location, no date) never counts for a place anyway.
///
/// Why "maybe" counts for nothing: the rules miss window photos (listed in `AirborneFilter`),
/// most of them with one flown leg: a flight's first or last window photos when the gate photo
/// was taken hours before, a pair of photos on a short flight, a series that does not head on.
/// One such photo costs at most its town; but a country needs three photos in the whole library,
/// not per flight, so two missed window photos on the way out and one on the way back made
/// France a visited country. Seen from its legs, a photo with one flown leg and no stay may as
/// well be a window photo as one at the gate, so it proves nothing. What does: a stay (photos in
/// a row that did not move on, as a layover's photos minutes apart), or legs no faster than
/// ground transport (a road trip, a walk over a border, a fast train).
///
/// The price: a single photo at an airport next to a flown leg (a gate photo before a flight
/// without window photos, an arrival photo after one) counts for no town where it is that town's
/// only photo. Window photos with no flown leg (no photo within `maximumLongLegDuration` on one
/// side, a slow leg on the other) still count: a town each, a country only with three of them.
public struct FlightJudgement: Sendable, Equatable {
    /// Taken in flight: rules 1 to 4 of `AirborneFilter`.
    public var airborne: Set<AssetID>
    /// Maybe taken in flight; none of them is in `airborne`.
    public var maybeInFlight: Set<AssetID>

    public init(airborne: Set<AssetID> = [], maybeInFlight: Set<AssetID> = []) {
        self.airborne = airborne
        self.maybeInFlight = maybeInFlight
    }

    /// Whether the photo counts: neither taken in flight nor maybe.
    public func isOnTheGround(_ id: AssetID) -> Bool { !airborne.contains(id) && !maybeInFlight.contains(id) }
}

/// The judged photos of a library in time order, with the rules of `AirborneFilter` on them. Kept
/// as arrays of plain values: a large library reads them some hundred thousand times.
///
/// The work stays about linear in the number of photos, however dense the library. A search for a
/// photo's neighbour passes only photos closer to it than `minimumLegMeters`, and
/// - stops after a minute of them for rules 2 to 4: they make a stay (`stayDuration`), so the
///   photo is no window photo whatever lies beyond. A day of thousands of photos whose location
///   jumps between spots a kilometre or two apart indoors would otherwise read the whole day for
///   every photo of it;
/// - stops where no photo further on can end a leg faster than ground transport (`earliest`,
///   `latest`), when only such a leg matters; most photos are not searched at all;
/// - passes groups (`AirborneFilter.groupRadiusMeters`) whole, and is kept (`Neighbours`).
///
/// Rule 4 judges only photos within `runEndLongDuration` of a photo of rules 1 to 3.
struct FlightTrack: Sendable {
    /// Time order; equal times by id, then by location (so a library holding one id twice still
    /// has one order, whatever order it came in).
    let ids: [AssetID]
    let times: [TimeInterval]
    let coordinates: [GeoCoordinate]
    /// The stated horizontal accuracy of each location in metres, 0 where unknown.
    let accuracies: [Double]
    /// `steps[k]`: the distance from photo `k - 1` to photo `k` (0 for the first).
    let steps: [Double]
    /// `pathMeters[k]`: the steps up to photo `k` added up. No two photos lie further apart than
    /// the way between them, so a search for a photo near one can pass the photos the way
    /// cannot bring near enough (`comesBack`).
    let pathMeters: [Double]
    /// The first and last photo at most `maximumLongLegDuration` before and after each photo.
    let windowStart: [Int]
    let windowEnd: [Int]
    /// Where a search for a leg faster than ground transport can stop: no photo before
    /// `earliest[i]` (after `latest[i]`) can end one at `i`; `i` itself when no photo can.
    ///
    /// The search for the neighbour before `i` passes only photos closer to `i` than
    /// `minimumLegMeters`, so the neighbour `j` it finds is at most that plus the step from `j` to
    /// the photo after it. The leg is fast only if that step exceeds `maximumGroundSpeed` times the
    /// time from `j` to `i`, less `minimumLegMeters`: `earliest[i]` is the first photo in the window
    /// with such a step. On the ground, steps fall behind by minutes; only flights, fast trains,
    /// wrong locations and photos seconds apart make one. Once a photo's step falls short for `i`,
    /// it falls short for every later photo, so one pointer moving forward finds them all (and for
    /// the leg after, one moving back).
    ///
    /// The search passes photos out of reach as well (`AirborneFilter.jumpMeters`), and the bound
    /// holds until it has passed one: the first such photo `k` it meets lies further from `i` than
    /// `maximumFlightSpeed` covers in their time, the photo after `k` closer than
    /// `minimumLegMeters`, so `k`'s step is long enough not to lie before `earliest[i]`. Past it
    /// the search goes on unbounded.
    let earliest: [Int]
    let latest: [Int]
    /// As `earliest` and `latest`, for a leg faster than `AirborneFilter.turnBackSpeed` (the turn
    /// back of rule 2).
    let turnEarliest: [Int]
    let turnLatest: [Int]
    /// The first photo of each group (`AirborneFilter.groupRadiusMeters`), ascending.
    private let groupStarts: [Int]
    /// The group of each photo.
    private let groupOf: [Int]

    /// Any distance computed may be off by far less than this from the true one. A group is only
    /// passed or taken whole when this far clear of `minimumLegMeters` (else its photos are read
    /// one by one), so the shortcut gives exactly the photo-by-photo result.
    static let roundingMarginMeters = 1.0
    /// `earliest` and `latest` add a step to a leg's length: they only rule a photo out when this
    /// far clear, so rounding never rules out one the rules would take.
    static let boundMarginMeters = 100.0

    init(_ photos: [AssetSnapshot]) {
        var ids: [AssetID] = [], times: [TimeInterval] = [], coordinates: [GeoCoordinate] = [], accuracies: [Double] = []
        ids.reserveCapacity(photos.count)
        times.reserveCapacity(photos.count)
        coordinates.reserveCapacity(photos.count)
        accuracies.reserveCapacity(photos.count)
        for photo in photos {
            guard let coordinate = photo.usableLocation, let date = photo.creationDate, !photo.isScreenshotLike else { continue }
            ids.append(photo.id)
            times.append(date.timeIntervalSinceReferenceDate)
            coordinates.append(coordinate)
            accuracies.append(photo.locationAccuracy.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0)
        }
        // By time; the rest of the key only for equal times, which are rare.
        let order = times.indices.sorted { a, b in
            if times[a] != times[b] { return times[a] < times[b] }
            if ids[a] != ids[b] { return ids[a] < ids[b] }
            if coordinates[a].latitude != coordinates[b].latitude { return coordinates[a].latitude < coordinates[b].latitude }
            return coordinates[a].longitude < coordinates[b].longitude
        }
        self.ids = order.map { ids[$0] }
        self.times = order.map { times[$0] }
        self.coordinates = order.map { coordinates[$0] }
        self.accuracies = order.map { accuracies[$0] }
        let count = order.count, sorted = self.times, located = self.coordinates

        var groupStarts: [Int] = [], groupOf = [Int](repeating: 0, count: count)
        var steps = [Double](repeating: 0, count: count), pathMeters = steps
        for i in 0..<count {
            if i > 0 {
                steps[i] = GeoMath.distance(located[i - 1], located[i])
                pathMeters[i] = pathMeters[i - 1] + steps[i]
            }
            if let start = groupStarts.last, GeoMath.distance(located[start], located[i]) <= AirborneFilter.groupRadiusMeters {
                groupOf[i] = groupStarts.count - 1
            } else {
                groupStarts.append(i)
                groupOf[i] = groupStarts.count - 1
            }
        }
        self.groupStarts = groupStarts
        self.groupOf = groupOf
        self.steps = steps
        self.pathMeters = pathMeters

        let speed = AirborneFilter.maximumGroundSpeed, turn = AirborneFilter.turnBackSpeed
        let window = AirborneFilter.maximumLongLegDuration, reach = AirborneFilter.minimumLegMeters + Self.boundMarginMeters
        var windowStart = [Int](repeating: 0, count: count), earliest = windowStart, turnEarliest = windowStart
        var start = 0, first = 0, turnFirst = 0
        for i in 0..<count {
            while sorted[i] - sorted[start] > window { start += 1 }
            windowStart[i] = start
            first = max(first, start)
            while first < i && steps[first + 1] <= speed * (sorted[i] - sorted[first]) - reach { first += 1 }
            earliest[i] = first
            turnFirst = max(turnFirst, start)
            while turnFirst < i && steps[turnFirst + 1] <= turn * (sorted[i] - sorted[turnFirst]) - reach { turnFirst += 1 }
            turnEarliest[i] = turnFirst
        }
        var windowEnd = [Int](repeating: 0, count: count), latest = windowEnd, turnLatest = windowEnd
        var end = count - 1, last = count - 1, turnLast = count - 1
        for i in stride(from: count - 1, through: 0, by: -1) {
            while sorted[end] - sorted[i] > window { end -= 1 }
            windowEnd[i] = end
            last = min(last, end)
            while last > i && steps[last] <= speed * (sorted[last] - sorted[i]) - reach { last -= 1 }
            latest[i] = last
            turnLast = min(turnLast, end)
            while turnLast > i && steps[turnLast] <= turn * (sorted[turnLast] - sorted[i]) - reach { turnLast -= 1 }
            turnLatest[i] = turnLast
        }
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.earliest = earliest
        self.latest = latest
        self.turnEarliest = turnEarliest
        self.turnLatest = turnLatest
    }

    // MARK: Distances and legs

    /// The ids of the photos whose flag is set.
    func ids(where flags: [Bool]) -> Set<AssetID> {
        var result = Set<AssetID>()
        for i in flags.indices where flags[i] { result.insert(ids[i]) }
        return result
    }

    /// The distance between two photos, always measured from the earlier one.
    func meters(_ a: Int, _ b: Int) -> Double {
        a <= b ? GeoMath.distance(coordinates[a], coordinates[b]) : GeoMath.distance(coordinates[b], coordinates[a])
    }

    func seconds(_ a: Int, _ b: Int) -> TimeInterval { (times[b] - times[a]).magnitude }

    /// Faster than `AirborneFilter.turnBackSpeed` (equal times included, at any distance above
    /// zero): a leg on which a run turns back when it leaves the way.
    func fasterThanTurnBack(_ a: Int, _ b: Int) -> Bool { meters(a, b) > AirborneFilter.turnBackSpeed * seconds(a, b) }

    /// Flown: faster than ground transport, not faster than a plane.
    func flown(_ a: Int, _ b: Int) -> Bool {
        let meters = meters(a, b), seconds = seconds(a, b)
        return meters > AirborneFilter.maximumGroundSpeed * seconds && meters <= AirborneFilter.maximumFlightSpeed * seconds
    }

    /// Whether the way from `a` to the later `b` leaves time to land or take off on it
    /// (`AirborneFilter.landingDuration`): it was no faster than ground transport, or a plane at
    /// `maximumFlightSpeed` covers it in its time less `landingDuration`.
    func leavesTimeToLand(_ a: Int, _ b: Int) -> Bool {
        let meters = meters(a, b), seconds = seconds(a, b)
        return meters <= AirborneFilter.maximumGroundSpeed * seconds
            || meters <= AirborneFilter.maximumFlightSpeed * (seconds - AirborneFilter.landingDuration)
    }

    /// `middle` on the way from `from` to `to` (`AirborneFilter.detourFactor`).
    func onTheWay(_ from: Int, _ middle: Int, _ to: Int) -> Bool {
        meters(from, middle) + meters(middle, to) <= AirborneFilter.detourFactor * meters(from, to) + AirborneFilter.detourAllowanceMeters
    }

    // MARK: Judging

    /// Per photo, whether it was taken in flight: `high` (rule 1, by altitude) or rules 2 to 4;
    /// `aloft`: whether its stored altitude is above `AirborneFilter.aloftAltitude` (rule 3).
    func inFlight(high: [Bool], aloft: [Bool]) -> [Bool] {
        judge(high: high, aloft: aloft, maybe: false).inFlight
    }

    /// As `inFlight`, and with `maybe`, per photo not taken in flight whether it maybe was
    /// (`FlightJudgement`; empty without).
    func judge(high: [Bool], aloft: [Bool], maybe withMaybe: Bool) -> (inFlight: [Bool], maybe: [Bool]) {
        // Plain local arrays in the loops: a debug build reads a property far slower.
        let times = self.times, earliest = self.earliest, latest = self.latest, count = times.count
        guard count > 0 else { return ([], []) }
        var neighbours = Neighbours(count: count)

        var onRun = [Bool](repeating: false, count: count)
        for i in 0..<count where earliest[i] < i && latest[i] > i {
            onRun[i] = isOnRun(i, neighbours: &neighbours)
        }
        var bursts = Bursts(self, aloft: aloft)
        var start = 0
        while start < count {
            let end = bursts.last[start]
            guard end >= 0 else {
                start += 1
                continue
            }
            if !bursts.holdsFour[start] && !headsOn(start, end) { bursts.drop(start, end) }
            start = end + 1
        }
        let member = bursts.member
        var flags = [Bool](repeating: false, count: count)
        for i in 0..<count where high[i] || onRun[i] || member[i] {
            flags[i] = high[i] || onRun[i] || !comesBack(i)
        }
        let confirmed = flags

        // Rule 4 only within `runEndLongDuration` of a confirmed photo.
        let reach = AirborneFilter.runEndLongDuration
        var near = [Bool](repeating: false, count: count)
        var previous = -1, next = -1
        for i in 0..<count {
            if confirmed[i] { previous = i }
            near[i] = previous >= 0 && times[i] - times[previous] <= reach
        }
        for i in stride(from: count - 1, through: 0, by: -1) {
            if confirmed[i] { next = i }
            if next >= 0 && times[next] - times[i] <= reach { near[i] = true }
        }
        for i in 0..<count where !confirmed[i] && near[i] {
            flags[i] = endsRun(i, neighbours: &neighbours, confirmed: confirmed, onRun: onRun, bursts: bursts)
        }
        guard withMaybe else { return (flags, []) }

        // Maybe in flight: a photo with a leg faster than ground transport on one side at least.
        var maybe = [Bool](repeating: false, count: count)
        for i in 0..<count where !flags[i] && (earliest[i] < i || latest[i] > i) {
            maybe[i] = mayBeInFlight(i, neighbours: &neighbours)
        }
        return (flags, maybe)
    }

    /// Rule 2: both legs flown, on the way, no stay, no turn back.
    func isOnRun(_ i: Int, neighbours: inout Neighbours) -> Bool {
        let before = neighbours.runBefore(i, in: self)
        guard before >= 0, flown(before, i) else { return false }
        let after = neighbours.runAfter(i, in: self)
        guard after >= 0, flown(i, after), onTheWay(before, i, after) else { return false }
        if stays(i, before: before, after: after, landing: true) { return false }
        // A short leg from or to a stay.
        let short = AirborneFilter.runEndLongDuration
        if times[i] - times[before] <= short, staysAt(before, step: -1) { return false }
        if times[after] - times[i] <= short, staysAt(after, step: 1) { return false }
        // Turning back: the leg into the photo before (or out of the photo after) is faster than
        // `turnBackSpeed` and leaves the way.
        let previous = neighbours.turnBefore(before, in: self)
        if previous >= 0, !onTheWay(previous, before, i) { return false }
        let next = neighbours.turnAfter(after, in: self)
        if next >= 0, !onTheWay(i, after, next) { return false }
        return !comesBack(i)
    }

    /// Whether the photo at `i`, not taken in flight, maybe was (`FlightJudgement`): exactly one
    /// of its legs was flown, no short one to a stay, and rule 2's conditions hold with that leg:
    /// on the way, no stay (one moving on slower than `AirborneFilter.stayMovingSpeed`), no turn
    /// back, no coming back.
    func mayBeInFlight(_ i: Int, neighbours: inout Neighbours) -> Bool {
        var before = neighbours.runBefore(i, in: self), after = neighbours.runAfter(i, in: self)
        if before == Neighbours.staying || after == Neighbours.staying { return false }
        let short = AirborneFilter.runEndLongDuration
        let flownBefore = before >= 0 && flown(before, i) && !(times[i] - times[before] <= short && staysAt(before, step: -1))
        let flownAfter = after >= 0 && flown(i, after) && !(times[after] - times[i] <= short && staysAt(after, step: 1))
        // Both legs flown: rule 2 has judged it.
        guard flownBefore != flownAfter else { return false }
        // The other leg's neighbour wherever it is (the bounded search stops where no leg to one
        // can be faster than ground transport).
        if before < 0 { before = neighbour(of: i, step: -1, limit: 0, staying: true) }
        if after < 0 { after = neighbour(of: i, step: 1, limit: times.count - 1, staying: true) }
        if before == Neighbours.staying || after == Neighbours.staying { return false }
        if before >= 0, after >= 0, !onTheWay(before, i, after) { return false }
        if stays(i, before: before, after: after, movingSpeed: AirborneFilter.stayMovingSpeed) { return false }
        if before >= 0 {
            let previous = neighbours.turnBefore(before, in: self)
            if previous >= 0, !onTheWay(previous, before, i) { return false }
        }
        if after >= 0 {
            let next = neighbours.turnAfter(after, in: self)
            if next >= 0, !onTheWay(i, after, next) { return false }
        }
        return !comesBack(i)
    }

    /// Rule 4: the photo next to a confirmed run, on a short flown leg to it.
    func endsRun(_ i: Int, neighbours: inout Neighbours, confirmed: [Bool], onRun: [Bool], bursts: Bursts) -> Bool {
        for later in [true, false] {
            // The run's side first: its leg is fast, so the bounded search finds it.
            let run = later ? neighbours.runAfter(i, in: self) : neighbours.runBefore(i, in: self)
            if run == Neighbours.staying { return false }
            guard run >= 0, confirmed[run], flown(i, run) else { continue }
            let duration = seconds(i, run)
            guard duration <= AirborneFilter.runEndLongDuration,
                  duration <= AirborneFilter.runEndDuration || meters(i, run) > AirborneFilter.runEndLongSpeed * duration else { continue }
            let other = neighbour(of: i, step: later ? -1 : 1, limit: later ? 0 : times.count - 1, staying: true)
            if other == Neighbours.staying { return false }
            if other >= 0, !(later ? onTheWay(other, i, run) : onTheWay(run, i, other)) { continue }
            // The run goes on in a line beyond that photo: to its own other neighbour, or to the
            // far end of its burst. (A photo confirmed by its altitude alone needs no line.)
            let far = onRun[run] ? (later ? neighbours.runAfter(run, in: self) : neighbours.runBefore(run, in: self))
                : bursts.member[run] ? (later ? bursts.last[run] : bursts.first[run]) : -1
            if far >= 0, far != run, !(later ? onTheWay(i, run, far) : onTheWay(far, run, i)) { continue }
            return !stays(i, before: later ? other : run, after: later ? run : other) && !comesBack(i)
        }
        return false
    }

    /// Whether the photo at `i` shows a stay: the photos in a row around it closer than
    /// `minimumLegMeters` (between its neighbours `before` and `after`, or as far as
    /// `maximumLongLegDuration` where it has none; photos out of reach between them, which the
    /// neighbours' search passes, are someone else's and left out), when they last at least
    /// `AirborneFilter.shortestStay`, did not move on along its legs (away from the photo before,
    /// towards the photo after; without either, apart) faster than `movingSpeed` over their time
    /// (`maximumGroundSpeed`; `AirborneFilter.stayMovingSpeed` next to a single flown leg), nor
    /// further than the stated accuracy of the first and last of them. In a plane such photos lie
    /// under a minute apart and move on at its speed; on the ground they stay within the 6 km the
    /// row can span, however long it lasts. A single photo shows nothing, nor do photos within
    /// `AirborneFilter.shortestStay`, whose fixes may lag a second's flight behind them. With
    /// `landing` (rule 2), a row on one fix lasting under `stayDuration` on either side of the
    /// photo shows none either where a plane could not have landed after the leg before it, or
    /// taken off before the leg after it (`AirborneFilter.landingDuration`).
    func stays(_ i: Int, before: Int, after: Int, movingSpeed: Double = AirborneFilter.maximumGroundSpeed, landing: Bool = false) -> Bool {
        var first = before >= 0 ? before + 1 : windowStart[i], last = after >= 0 ? after - 1 : windowEnd[i]
        while first < i && meters(first, i) >= AirborneFilter.minimumLegMeters { first += 1 }
        while last > i && meters(i, last) >= AirborneFilter.minimumLegMeters { last -= 1 }
        guard first < last else { return false }
        let span = times[last] - times[first]
        guard span >= AirborneFilter.shortestStay else { return false }
        if landing && coordinates[first] == coordinates[last]
            && times[i] - times[first] < AirborneFilter.stayDuration && times[last] - times[i] < AirborneFilter.stayDuration
            && ((before >= 0 && !leavesTimeToLand(before, first)) || (after >= 0 && !leavesTimeToLand(last, after))) { return false }
        var progress = Double.infinity
        if before >= 0 { progress = min(progress, meters(before, last) - meters(before, first)) }
        if after >= 0 { progress = min(progress, meters(first, after) - meters(last, after)) }
        if before < 0 && after < 0 { progress = meters(first, last) }
        let movedOn = max(movingSpeed * span, accuracies[first] + accuracies[last])
        return progress < movedOn + Self.roundingMarginMeters
    }

    /// Whether the photo at `p` stays on its side `step` (-1 before, 1 after): the photos there
    /// closer than `minimumLegMeters`, up to its neighbour on that side (or as far as
    /// `maximumLongLegDuration` where it has none), reach `stayDuration` from it. A minute and more
    /// of photos within 3 km is a stop, not a plane: one at 400 km/h leaves 3 km behind in 27 s.
    func staysAt(_ p: Int, step: Int) -> Bool {
        neighbour(of: p, step: step, limit: step < 0 ? 0 : times.count - 1, staying: true) == Neighbours.staying
    }

    /// Rule 3: whether the burst from `start` to `end` heads on. Its legs go to the nearest photo
    /// before its first photo and the nearest after its last that are at least `minimumLegMeters`
    /// from them and at most `maximumLongLegDuration` apart: it needs one, and its way away from
    /// the photo before and towards the photo after must each be at least
    /// `AirborneFilter.burstHeading` of its length. A minute of photos near its first photo before
    /// it, or near its last after it (`Neighbours.staying`), is a stay, never a plane's.
    func headsOn(_ start: Int, _ end: Int) -> Bool {
        let before = neighbour(of: start, step: -1, limit: 0, staying: true)
        guard before != Neighbours.staying else { return false }
        let after = neighbour(of: end, step: 1, limit: times.count - 1, staying: true)
        guard after != Neighbours.staying, before >= 0 || after >= 0 else { return false }
        let way = AirborneFilter.burstHeading * meters(start, end)
        if before >= 0 && meters(before, end) - meters(before, start) < way { return false }
        if after >= 0 && meters(start, after) - meters(end, after) < way { return false }
        return true
    }

    /// Whether the location comes back to the photo at `i` (`AirborneFilter.returnDuration`): a
    /// photo `stayDuration` to `returnDuration` before or after it lies closer than
    /// `minimumLegMeters`. A photo `d` away is followed by none nearer than `d` less the way
    /// from it, so the search passes such photos with a look at `pathMeters` alone: a flight's
    /// photos, ever further away, cost a handful of distances.
    func comesBack(_ i: Int) -> Bool {
        let time = times[i], near = AirborneFilter.minimumLegMeters, margin = Self.roundingMarginMeters
        let stay = AirborneFilter.stayDuration, window = AirborneFilter.returnDuration
        // After it (from a second early on; the time is checked as the rule states it).
        var k = Self.firstIndex(times, atLeast: time + stay - 1, from: i + 1)
        while k < times.count && times[k] - time <= window {
            let d = meters(i, k)
            if d < near && times[k] - time >= stay { return true }
            k = max(k + 1, Self.firstIndex(pathMeters, atLeast: pathMeters[k] + d - near - margin, from: k + 1))
        }
        // Before it.
        k = Self.firstIndex(times, above: time - stay + 1, below: i) - 1
        while k >= 0 && time - times[k] <= window {
            let d = meters(k, i)
            if d < near && time - times[k] >= stay { return true }
            k = min(k - 1, Self.firstIndex(pathMeters, above: pathMeters[k] - (d - near - margin), below: k) - 1)
        }
        return false
    }

    /// The first index from `low` on (the array's end if none) whose value is at least `value`,
    /// in an ascending array.
    static func firstIndex(_ values: [Double], atLeast value: Double, from low: Int) -> Int {
        var low = low, high = values.count
        while low < high {
            let middle = (low + high) / 2
            if values[middle] < value { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The first index below `end` (`end` if none) whose value is above `value`, in an ascending
    /// array.
    static func firstIndex(_ values: [Double], above value: Double, below end: Int) -> Int {
        var low = 0, high = end
        while low < high {
            let middle = (low + high) / 2
            if values[middle] <= value { low = middle + 1 } else { high = middle }
        }
        return low
    }

    // MARK: Neighbours

    /// The nearest photo before (`step` -1) or after (`step` 1) the photo at `i` that is at least
    /// `minimumLegMeters` from it, at most `maximumLongLegDuration` apart in time and not **out of
    /// reach** (`AirborneFilter.jumpMeters`), or -1; -1 too once the search would pass `limit` (a
    /// photo index) before it has passed a photo out of reach. With `staying`,
    /// `Neighbours.staying` once it passes a photo closer than `minimumLegMeters` that is
    /// `stayDuration` or more from it: the photos in a row around it then make a stay of that
    /// length (`stays`).
    ///
    /// A photo out of reach is someone else's (an iCloud Shared Library: someone at home while the
    /// other flies) or a wrong location far off. It says nothing about this photo's way, so the
    /// search passes it, as the trip's route does. Taken as the neighbour, the photos at home hid
    /// the window photos between them: their legs were no flight (faster than a plane, or there
    /// and back), and a series did not head on towards a photo at home behind the plane. `limit`
    /// holds until the search has passed such a photo (see `earliest`); from there on it is lifted.
    ///
    /// Read group by group: the photos of the photo's own group are all closer than a leg; a
    /// group whose first photo is far enough clear of `minimumLegMeters` is passed or taken whole
    /// (each of its photos lies within `groupRadiusMeters` of its first), and so is a group far
    /// enough from it whose photos are all within reach or all out of it; any other group is read
    /// photo by photo. The time bound ends the search.
    func neighbour(of i: Int, step: Int, limit: Int, staying: Bool) -> Int {
        let time = times[i]
        let minimum = AirborneFilter.minimumLegMeters, window = AirborneFilter.maximumLongLegDuration
        let radius = AirborneFilter.groupRadiusMeters, margin = Self.roundingMarginMeters
        let speed = AirborneFilter.maximumFlightSpeed, jump = AirborneFilter.jumpMeters
        let stay = staying ? AirborneFilter.stayDuration : .infinity
        let unbounded = step < 0 ? 0 : times.count - 1
        var limit = limit
        func groupEnd(_ group: Int) -> Int { group + 1 < groupStarts.count ? groupStarts[group + 1] - 1 : times.count - 1 }
        // Whether a group's photos on this side within the window reach `stay` from the photo.
        func reachesStay(_ group: Int) -> Bool {
            let edge = step < 0 ? max(groupStarts[group], windowStart[i]) : min(groupEnd(group), windowEnd[i])
            return (times[edge] - time).magnitude >= stay
        }
        if reachesStay(groupOf[i]) { return Neighbours.staying }
        var group = groupOf[i] + step
        while group >= 0 && group < groupStarts.count {
            let first = groupStarts[group], last = groupEnd(group)
            let nearest = step < 0 ? last : first
            if step < 0 ? nearest < limit : nearest > limit { return -1 }
            guard (times[nearest] - time).magnitude <= window else { return -1 }
            let anchor = meters(first, i)
            if anchor + radius + margin < minimum {
                if reachesStay(group) { return Neighbours.staying }
                group += step
                continue
            }
            if anchor - radius - margin >= minimum {
                // All far enough: the nearest in time if surely within reach; passed whole if all
                // its photos within the window are surely out of reach.
                if anchor + radius + margin <= speed * (times[nearest] - time).magnitude + jump { return nearest }
                let farthest = step < 0 ? max(first, windowStart[i]) : min(last, windowEnd[i])
                if anchor - radius - margin > speed * (times[farthest] - time).magnitude + jump {
                    limit = unbounded
                    group += step
                    continue
                }
            }
            // Its photos one by one, nearest in time first.
            var j = nearest
            while j >= first && j <= last {
                if step < 0 ? j < limit : j > limit { return -1 }
                let seconds = (times[j] - time).magnitude
                guard seconds <= window else { return -1 }
                let meters = meters(j, i)
                if meters >= minimum {
                    if meters <= speed * seconds + jump { return j }
                    limit = unbounded
                } else if seconds >= stay {
                    return Neighbours.staying
                }
                j += step
            }
            group += step
        }
        return -1
    }

    /// The searches done so far, so no photo is searched twice (`unknown`: not yet).
    struct Neighbours {
        static let unknown = -2
        static let staying = -3

        /// For rules 2 and 4: the neighbour, if a leg to it can be faster than ground transport
        /// (else -1), or `staying`.
        private var runEarlier: [Int]
        private var runLater: [Int]
        /// For the turn back: the neighbour, if the leg to it is faster than
        /// `AirborneFilter.turnBackSpeed` (else -1).
        private var turnEarlier: [Int]
        private var turnLater: [Int]

        init(count: Int) {
            runEarlier = [Int](repeating: Self.unknown, count: count)
            runLater = runEarlier
            turnEarlier = runEarlier
            turnLater = runEarlier
        }

        mutating func runBefore(_ i: Int, in track: FlightTrack) -> Int {
            if runEarlier[i] == Self.unknown { runEarlier[i] = track.neighbour(of: i, step: -1, limit: track.earliest[i], staying: true) }
            return runEarlier[i]
        }

        mutating func runAfter(_ i: Int, in track: FlightTrack) -> Int {
            if runLater[i] == Self.unknown { runLater[i] = track.neighbour(of: i, step: 1, limit: track.latest[i], staying: true) }
            return runLater[i]
        }

        /// The search for a run's neighbour is bounded for legs faster than ground transport, so
        /// only a neighbour it found is the turn back's too.
        mutating func turnBefore(_ i: Int, in track: FlightTrack) -> Int {
            if turnEarlier[i] == Self.unknown {
                var j = runEarlier[i]
                if j < 0 { j = track.neighbour(of: i, step: -1, limit: track.turnEarliest[i], staying: false) }
                turnEarlier[i] = j >= 0 && track.fasterThanTurnBack(j, i) ? j : -1
            }
            return turnEarlier[i]
        }

        mutating func turnAfter(_ i: Int, in track: FlightTrack) -> Int {
            if turnLater[i] == Self.unknown {
                var j = runLater[i]
                if j < 0 { j = track.neighbour(of: i, step: 1, limit: track.turnLatest[i], staying: false) }
                turnLater[i] = j >= 0 && track.fasterThanTurnBack(i, j) ? j : -1
            }
            return turnLater[i]
        }
    }

    // MARK: Bursts

    /// Rule 3: the photos in a burst, and for each the first and last photo of its burst (bursts
    /// sharing a photo are one) and whether its burst holds four photos in a row that move steadily
    /// and straight on over all four; -1 and false elsewhere.
    struct Bursts {
        var member: [Bool]
        var first: [Int]
        var last: [Int]
        var holdsFour: [Bool]

        /// `aloft`: per photo, whether its stored altitude is above `AirborneFilter.aloftAltitude`.
        init(_ track: FlightTrack, aloft: [Bool]) {
            let times = track.times, steps = track.steps, accuracies = track.accuracies, count = times.count
            member = [Bool](repeating: false, count: count)
            first = [Int](repeating: -1, count: count)
            last = [Int](repeating: -1, count: count)
            holdsFour = member
            var chain = (start: -1, end: -1, four: false)
            func close() {
                guard chain.start >= 0 else { return }
                for p in chain.start...chain.end {
                    member[p] = true
                    first[p] = chain.start
                    last[p] = chain.end
                    holdsFour[p] = chain.four
                }
            }
            /// Whether the steps from photo `start` to photo `end` are steady and straight on.
            func steady(_ start: Int, _ end: Int) -> Bool {
                var slowest = Double.infinity, fastest = 0.0, path = 0.0
                for m in (start + 1)...end {
                    let speed = steps[m] / (times[m] - times[m - 1])
                    slowest = min(slowest, speed)
                    fastest = max(fastest, speed)
                    path += steps[m]
                }
                return fastest <= AirborneFilter.burstSpeedRatio * slowest && path <= AirborneFilter.burstStraightness * track.meters(start, end)
            }
            // `streak`: how many steps in a row up to photo `k` fly (seconds apart, long enough, at
            // the speed of a plane).
            var streak = 0
            for k in 1..<max(1, count) {
                let seconds = times[k] - times[k - 1], meters = steps[k]
                let speed = aloft[k - 1] && aloft[k] ? AirborneFilter.aloftBurstSpeed : AirborneFilter.burstSpeed
                let flies = seconds > 0 && seconds <= AirborneFilter.burstStepDuration
                    && meters >= max(AirborneFilter.burstStepMeters, accuracies[k - 1] + accuracies[k])
                    && meters > speed * seconds && meters <= AirborneFilter.maximumFlightSpeed * seconds
                streak = flies ? streak + 1 : 0
                guard streak >= AirborneFilter.burstPhotos - 1 else { continue }
                // The four photos up to `k`, else the three.
                let four = streak >= 3 && steady(k - 3, k)
                let start = four ? k - 3 : k - AirborneFilter.burstPhotos + 1
                guard four || steady(start, k) else { continue }
                if chain.start >= 0 && start <= chain.end {
                    chain.end = k
                    chain.four = chain.four || four
                } else {
                    close()
                    chain = (start, k, four)
                }
            }
            close()
        }

        /// Takes the burst from `start` to `end` out.
        mutating func drop(_ start: Int, _ end: Int) {
            for p in start...end {
                member[p] = false
                first[p] = -1
                last[p] = -1
                holdsFour[p] = false
            }
        }
    }
}
