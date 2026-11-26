import Foundation
import AlbumistCore

/// What one flight of the probe measured (`CameraProbeFlightRun`).
public struct CameraProbeFlightResult: Hashable, Sendable {
    /// From setting the first camera to the first fully rendered map; `nil` when
    /// `CameraProbe.waitSeconds` ran out first (the flight starts then anyway).
    public var startReadySeconds: Double?
    /// How long the flight really took, by the display link's clock.
    public var flownSeconds: Double
    /// Of those, how long Apple's map was rendering: from MapKit's "will start rendering" to its
    /// next "did finish rendering". The map shows what it has meanwhile, often blurred or empty.
    public var unfinishedSeconds: Double
    /// Renderings during the flight and the landing that finished without the whole map.
    public var incompleteRenderings: Int
    /// The frames the display link gave during the flight, and those it left out.
    public var frames: Int
    public var droppedFrames: Int
    /// From the end of the flight until the map stood fully rendered: 0 when it already was,
    /// `nil` when the wait ran out or the last rendering was not whole.
    public var landedReadySeconds: Double?
    /// What went over the network from the start of the flight to the end of the landing.
    public var network: MapMeasurements.NetworkUse?
    /// The iPhone's heat at the end.
    public var heat: MapMeasurements.Thermal
}

/// One flight of the probe as it happens, fed by the app: MapKit's rendering callbacks, the
/// display link's frames and the moments of take-off and landing, all on the clock of
/// `CACurrentMediaTime`. The app sets the first camera and makes the run (`starting`); once that
/// map is fully rendered (`readyToTakeOff`) or the wait is over it takes off and sets the
/// flight's camera on every frame (`flying`); after the last it lands (`landing`) and asks
/// `settle(at:)` until the map has been at rest for `restSeconds` (`done`, with `result`). A run
/// the app left in the middle is `abandoned` and measures nothing.
public struct CameraProbeFlightRun: Hashable, Sendable {
    public enum Phase: Hashable, Sendable { case starting, flying, landing, done, abandoned }

    /// After the landing the map counts as ready once no rendering started for this long.
    public static let restSeconds = 0.5

    public private(set) var phase = Phase.starting
    public private(set) var startReadySeconds: Double?
    public private(set) var frames = 0
    public private(set) var droppedFrames = 0
    public private(set) var unfinishedSeconds = 0.0
    public private(set) var incompleteRenderings = 0
    public private(set) var landedReadySeconds: Double?

    private let shownAt: Double
    private var renderedSinceShown = false
    /// MapKit renders since then; `nil` while its map is at rest.
    private var renderingSince: Double?
    private var tookOffAt: Double?
    private var landedAt: Double?
    private var lastFrame: Double?
    /// The last event after the landing (a rendering started or finished), and whether the last
    /// rendering of the flight or the landing finished whole.
    private var lastLandingEvent: Double?
    private var lastFinishedWhole = true
    private var lastWholeFinish: Double?

    /// The first camera was set at `shownAt`. `renderingInProgress`: MapKit was still rendering
    /// then; it sends no new "will start" for the new camera, so its next whole finish counts.
    public init(shownAt: Double, renderingInProgress: Bool = false) {
        self.shownAt = shownAt
        if renderingInProgress {
            renderingSince = shownAt
            renderedSinceShown = true
        }
    }

    /// The first map is fully rendered: the flight may start.
    public var readyToTakeOff: Bool { phase == .starting && startReadySeconds != nil }

    /// Seconds flown at `time`; 0 before the take-off.
    public func flown(at time: Double) -> Double {
        guard let tookOffAt else { return 0 }
        return max(0, (landedAt ?? time) - tookOffAt)
    }

    public mutating func renderingStarted(at time: Double) {
        if renderingSince == nil { renderingSince = time }
        renderedSinceShown = true
        if phase == .landing { lastLandingEvent = time }
    }

    public mutating func renderingFinished(at time: Double, fully: Bool) {
        if let since = renderingSince, phase == .flying, let tookOffAt {
            unfinishedSeconds += max(0, time - max(since, tookOffAt))
        }
        renderingSince = nil
        if phase == .flying || phase == .landing, !fully { incompleteRenderings += 1 }
        switch phase {
        case .starting:
            if fully, renderedSinceShown, startReadySeconds == nil { startReadySeconds = max(0, time - shownAt) }
        case .flying:
            lastFinishedWhole = fully
            if fully { lastWholeFinish = time }
        case .landing:
            lastLandingEvent = time
            lastFinishedWhole = fully
            if fully { lastWholeFinish = time }
        case .done, .abandoned:
            break
        }
    }

    /// The flight begins: the start map is ready, or the wait for it is over.
    public mutating func takeOff(at time: Double) {
        guard phase == .starting else { return }
        phase = .flying
        tookOffAt = time
        lastFrame = nil
    }

    /// A frame of the display link during the flight: `expected` is the time one frame should
    /// take (its target time minus its time). A frame that came later counts the frames left out.
    public mutating func frame(at time: Double, expected: Double) {
        guard phase == .flying else { return }
        frames += 1
        if let lastFrame, expected > 0, time > lastFrame {
            droppedFrames += max(0, Int(((time - lastFrame) / expected).rounded()) - 1)
        }
        lastFrame = time
    }

    /// The last camera of the flight is set. A rendering still running counts until now.
    public mutating func land(at time: Double) {
        guard phase == .flying else { return }
        if let since = renderingSince, let tookOffAt {
            unfinishedSeconds += max(0, time - max(since, tookOffAt))
            renderingSince = time
        }
        phase = .landing
        landedAt = time
    }

    /// The app left the foreground: the display link paused, so the times would hold the pause.
    /// The run ends without a measurement.
    public mutating func abandon() {
        guard phase != .done else { return }
        phase = .abandoned
    }

    /// After the landing: done once the map rested `restSeconds` (ready when its last rendering
    /// finished whole: at that rendering's end, else 0 when none was needed), or after
    /// `CameraProbe.waitSeconds` without that (not ready).
    public mutating func settle(at time: Double) {
        guard phase == .landing, let landedAt else { return }
        let quietSince = lastLandingEvent ?? landedAt
        if renderingSince == nil, time - quietSince >= Self.restSeconds {
            phase = .done
            landedReadySeconds = lastFinishedWhole ? max(0, (lastWholeFinish ?? landedAt) - landedAt) : nil
        } else if time - landedAt >= CameraProbe.waitSeconds {
            phase = .done
            landedReadySeconds = nil
        }
    }

    /// The measurement once `done`.
    public func result(network: MapMeasurements.NetworkUse?, heat: MapMeasurements.Thermal) -> CameraProbeFlightResult? {
        guard phase == .done else { return nil }
        return CameraProbeFlightResult(startReadySeconds: startReadySeconds, flownSeconds: flown(at: landedAt ?? 0),
                                       unfinishedSeconds: unfinishedSeconds, incompleteRenderings: incompleteRenderings,
                                       frames: frames, droppedFrames: droppedFrames, landedReadySeconds: landedReadySeconds,
                                       network: network, heat: heat)
    }
}

extension CameraProbe {
    // MARK: The flight's words

    /// "Verlangt: 10,4 s in echter Zeit, 282 km Weg, Abstand 15 bis 145 km, 17° bis 29° über dem Horizont".
    public static var flightAsked: String {
        let distances = flight.keys.map(\.distanceMeters), angles = flight.keys.map(\.elevationDegrees)
        return "Verlangt: \(decimal(flight.seconds)) s in echter Zeit, \(Int(flight.groundKm.rounded())) km Weg, "
            + "Abstand \(Int(((distances.min() ?? 0) / 1_000).rounded())) bis \(kilometers(distances.max() ?? 0)), "
            + "\(degrees(angles.min() ?? 0)) bis \(degrees(angles.max() ?? 0)) über dem Horizont"
    }

    /// While flying: "Flug: 4,2 von 10,4 s · 112 km weit", and while the film would show the
    /// photo "· im Film unter dem Foto".
    public static func flightProgress(seconds: Double) -> String {
        let camera = flight.camera(at: seconds)
        var text = "Flug: \(decimal(seconds)) von \(decimal(flight.seconds)) s · \(kilometers(camera.distanceMeters)) weit"
        if flight.isCovered(at: seconds) { text += " · im Film unter dem Foto" }
        return text
    }

    /// "Karte nicht fertig 3,2 von 10,4 s · 2× nicht ganz geladen · 58 Bilder je s, 9 ausgelassen".
    public static func flightGot(_ result: CameraProbeFlightResult) -> String {
        var parts = ["Karte nicht fertig \(decimal(result.unfinishedSeconds)) von \(decimal(result.flownSeconds)) s"]
        if result.incompleteRenderings > 0 { parts.append("\(result.incompleteRenderings)× nicht ganz geladen") }
        let perSecond = result.flownSeconds > 0 ? Double(result.frames) / result.flownSeconds : .nan
        let rate = perSecond.isFinite ? "\(Int(perSecond.rounded()))" : "–"
        parts.append("\(rate) Bilder je s, \(result.droppedFrames) ausgelassen")
        return parts.joined(separator: " · ")
    }

    /// "Start fertig nach 2,1 s · nach der Landung fertig nach 1,4 s · 14,2 MB über WLAN · Wärme normal".
    public static func flightReadiness(_ result: CameraProbeFlightResult) -> String {
        let wait = "\(Int(waitSeconds)) s"
        let start = result.startReadySeconds.map { "Start fertig nach \(decimal($0)) s" } ?? "Start nach \(wait) nicht ganz geladen"
        let landed = result.landedReadySeconds.map { "nach der Landung fertig nach \(decimal($0)) s" }
            ?? "nach der Landung nicht ganz geladen"
        return [start, landed, megabytes(result.network), "Wärme \(result.heat.germanName)"].joined(separator: " · ")
    }

    /// "14,2 MB über WLAN", "3,0 MB über Mobilfunk", "0,0 MB"; "Datenmenge unbekannt" without counters.
    static func megabytes(_ use: MapMeasurements.NetworkUse?) -> String {
        guard let use else { return "Datenmenge unbekannt" }
        let total = "\(decimal(use.wifiMB + use.cellularMB)) MB"
        if use.wifiBytes == 0, use.cellularBytes == 0 { return total }
        return total + (use.cellularBytes > use.wifiBytes ? " über Mobilfunk" : " über WLAN")
    }

    /// The clipboard's lines for the flight: one per flight flown ("1 Flug Jökulsárlón bis
    /// Dettifoss, Lauf 2: …"), or one saying it was not flown.
    public static func flightLines(_ flights: [CameraProbeFlightResult]) -> [String] {
        let head = "1 Flug \(flight.from) bis \(flight.to)"
        guard !flights.isEmpty else { return ["\(head): noch nicht geflogen"] }
        return flights.enumerated().map { number, result in
            let got = flightGot(result).replacingOccurrences(of: " · ", with: ", ")
            let readiness = flightReadiness(result).replacingOccurrences(of: " · ", with: ", ")
            return "\(head), Lauf \(number + 1): \(readiness), \(got)"
        }
    }
}
