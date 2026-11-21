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
///    does not **come back** to it (`returnDuration`: no photo whose fix was taken one to five
///    minutes before or after its own lies within `minimumLegMeters`),
/// 2. **it lies on a run:** both its legs were flown, it lies on the way between them, it shows no
///    stay (`FlightTrack.stays`), no leg of at most `runEndLongDuration` leads to a photo that
///    stays (`FlightTrack.staysAt`), and the run does not turn back right before or after it (a
///    leg faster than `turnBackSpeed` that leaves the way); or
/// 3. **it is in a burst:** `burstPhotos` moments in a row (a photo on the fix of the photo before,
///    or within `sampleDuration` of a moment's first photo with no step of its own from it, is of
///    that moment, measured at its first photo), each at most `burstStepDuration` and at least
///    `burstStepMeters` after the one before, that move steadily (speeds above `burstSpeed`, or
///    above `aloftBurstSpeed` from one photo with a stored altitude above `aloftAltitude` to
///    another, not faster than a plane, within `burstSpeedRatio` of each other) and straight on
///    (`burstStraightness`), make a burst of all their photos; bursts sharing a moment are one. It
///    counts when it holds four such moments in a row (steady and straight over all four), or else
///    when it **heads on** (`FlightTrack.headsOn`): it has a leg (the leg before its first photo or
///    the leg after its last), its way from its first photo to its last takes it away from the
///    photo before and towards the photo after by at least `burstHeading` of that way's length, and
///    it shows no stay of `stayDuration` (a minute of fixes within `minimumLegMeters` of its first
///    photo before it, or of its last after it; a repeated fix is as old as the first photo on it,
///    `FlightTrack.fixTimes`); or
/// 4. **it ends a run:** one of its legs leads to a photo of rules 1 to 3, was flown and takes at
///    most `runEndDuration` (or `runEndLongDuration` when faster than `runEndLongSpeed`), the photo
///    lies on the way between its legs, the run goes on in a line beyond that photo, and the photo
///    shows no stay (no minute of photos near it, and no shorter row around it that moved on
///    slower than `stayMovingSpeed`).
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
/// `maximumAltitude`): a flight with window photos at fewer than three moments (`sampleDuration`),
/// unless its legs to the ground are flown (a short hop with two photos); the first or last window
/// photo more than `runEndDuration` (`runEndLongDuration`) before or after the next one (a
/// long-haul flight with a photo every few hours, unless its leg to the airport is flown), or off
/// the way (a turn after take-off); window photos next to photos someone else took within reach of
/// them (in a shared library, at home near the airport); photos whose location the iPhone did not
/// update in the plane for `shortestStay` and more where a plane could have landed, or for a minute
/// and more (they look like a stay); a burst of three that does not head on (in a turn, on a route
/// far off the line between the photos before and after it, or with no photo within
/// `maximumLongLegDuration` on either side); a series whose steps the age of its fixes makes uneven
/// (a fix a second old on a step of a second or two); a burst during the climb or descent slower
/// than `burstSpeed` (with stored altitudes: below `aloftAltitude` or slower than
/// `aloftBurstSpeed`), unless rule 4 takes it; photos of a plane circling back within 3 km in five
/// minutes (a holding pattern).
///
/// Ground photos it can take for window photos: three photos within seconds whose location jumps
/// 3 km and more in a straight line at a plane's speed with no photo near either end and none
/// coming back (and the other photos of their moments); three whose location slides like that along
/// the way from the photos before them to those after them, and four that slide like that anywhere
/// (rule 3: a coarse fix closing in, or a fix catching up after a tunnel on a fast train, stating
/// no accuracy; above `aloftAltitude`, with stored altitudes, a slide at `aloftBurstSpeed` is
/// enough, as on a mountain railway); one photo at a layover between two flown legs (or photos
/// there within `shortestStay`, or a few seconds of photos whose location jumps on along the
/// route); one photo half an hour from a place on the line between two others, once (Munich,
/// Florence, Rome); the odd photo of a location scattered further than 3 km within seconds.
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

    /// Rule 3 judges a series **moment** by moment. A photo is of the moment before it when it
    /// repeats the fix of the photo before (`FlightTrack.fixTimes`), or when it lies within this
    /// of the moment's first photo with no step of its own from it: shorter than
    /// `burstStepMeters` (or the stated accuracy of the two fixes), or faster than a plane. The
    /// iPhone updates the location about once a second, so within a second a photo carries the
    /// moment's fix or one a second newer, and such a step says nothing: a photo kept twice (HDR
    /// with "Keep Normal Photo", a duplicate) broke a series, and a photo half a second after a
    /// found series stayed behind and counted. A burst takes all photos of its moments. A photo
    /// within a second that moved on at a plane's speed is a moment of its own, as a series
    /// taken faster than a photo a second, its fix updated between them, needs it.
    static let sampleDuration: TimeInterval = 1
    /// Rule 3: a burst has at least this many moments (two steps) ...
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
    /// Next to a single flown leg (`FlightJudgement`), or to the flown leg to a confirmed photo
    /// (rule 4), a row of photos under a minute shows a stay only when it moved on slower than
    /// this. An airliner leaves the runway at 250 to 300 km/h and flies its last minutes before
    /// landing at 250 to 350 km/h, slower than `maximumGroundSpeed`, so a series of window photos
    /// there looks like a stay by that measure. On the ground only trains run faster than this,
    /// and a train's photos have no flown leg. 200 km/h, in metres per second.
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
