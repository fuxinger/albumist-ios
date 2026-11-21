import Foundation
import Testing
@testable import AlbumistMap

/// Data over the network (concept §9, "Mobile Daten"): a counter across a wrap and a restart, the use
/// added up per interface and kind and kept in a test result; and the two latest tests of each view
/// that are kept.
extension MapMeasurementsTests {
    // MARK: Data over the network (concept §9, "Mobile Daten")

    @Test func aCounterCountsItsDifferenceAcrossAWrapAndItsNewValueAfterARestart() {
        #expect(Metrics.NetworkLog.bytes(from: 1_000, to: 3_000) == 2_000)
        #expect(Metrics.NetworkLog.bytes(from: 7, to: 7) == 0)
        // 32 bits wrap after 4 GiB: 100 bytes to the top, 900 after it.
        #expect(Metrics.NetworkLog.bytes(from: UInt32.max - 99, to: 900) == 1_000)
        #expect(Metrics.NetworkLog.bytes(from: 0, to: Metrics.NetworkLog.plausibleBytesPerReading) == 256_000_000)
        // Gone down by more than a wrap could explain: the connection came back and counts anew.
        #expect(Metrics.NetworkLog.bytes(from: 3_000_000_000, to: 5_000) == 5_000)
        #expect(Metrics.NetworkLog.bytes(from: 3_000_000_000, to: 300_000_000) == 0)
        // An interface that came up during the test counts from zero.
        #expect(Metrics.NetworkLog.bytes(from: nil, to: 4_000) == 4_000)
        #expect(Metrics.NetworkLog.bytes(from: nil, to: 3_000_000_000) == 0)
    }

    @Test func theNetworkUseIsAddedUpPerInterfaceAndKind() {
        typealias Link = Metrics.NetworkCounters.Interface
        var log = Metrics.NetworkLog()
        #expect(log.result == nil)
        log.add(Metrics.NetworkCounters(interfaces: ["en0": Link(kind: .wifi, received: 1_000, sent: 500),
                                                     "pdp_ip0": Link(kind: .cellular, received: 100, sent: 50),
                                                     "pdp_ip1": Link(kind: .cellular, received: 9_000, sent: 0)]))
        #expect(log.result == nil && log.readings == 1)
        // Wi-Fi 2,200 bytes; the mobile network stands still; a second Wi-Fi-like link comes up.
        log.add(Metrics.NetworkCounters(interfaces: ["en0": Link(kind: .wifi, received: 3_000, sent: 700),
                                                     "pdp_ip0": Link(kind: .cellular, received: 100, sent: 50),
                                                     "pdp_ip1": Link(kind: .cellular, received: 9_000, sent: 0),
                                                     "en2": Link(kind: .wifi, received: 300, sent: 0)]))
        #expect(log.result == Metrics.NetworkUse(wifiBytes: 2_500, cellularBytes: 0))
        // pdp_ip1 goes away (adds nothing), pdp_ip0 loads 1.5 MB, en0 wraps.
        log.add(Metrics.NetworkCounters(interfaces: ["en0": Link(kind: .wifi, received: 3_000, sent: 700),
                                                     "pdp_ip0": Link(kind: .cellular, received: 1_500_100, sent: 50),
                                                     "en2": Link(kind: .wifi, received: 300, sent: 0)]))
        log.add(Metrics.NetworkCounters(interfaces: ["en0": Link(kind: .wifi, received: 3_000, sent: 700),
                                                     "pdp_ip0": Link(kind: .cellular, received: 1_500_100, sent: 50),
                                                     "en2": Link(kind: .cellular, received: 1_000, sent: 0)]))
        // en2 now counts as a mobile link of its own, from zero: 1,000 bytes.
        let use = log.result
        #expect(use == Metrics.NetworkUse(wifiBytes: 2_500, cellularBytes: 1_501_000) && log.readings == 4)
        #expect(use?.wifiMB == 0.0025 && use?.cellularMB == 1.501)
    }

    @Test func aTestResultKeepsItsNetworkUseAndOlderResultsStillDecode() throws {
        var result = Self.result()
        #expect(result.network == nil)
        let older = try JSONEncoder().encode(result)
        let olderText = try #require(String(bytes: older, encoding: .utf8))
        #expect(!olderText.contains("network"))
        #expect(try JSONDecoder().decode(Metrics.TestResult.self, from: older).network == nil)
        result.network = Metrics.NetworkUse(wifiBytes: 12_345_678, cellularBytes: 49_999)
        #expect(try JSONDecoder().decode(Metrics.TestResult.self, from: JSONEncoder().encode(result)) == result)
        let lines = Metrics.lines(results: [result], altitude: nil)
        #expect(lines.contains("map prototype own globe data: wifi 12.3 MB, cellular 0.0 MB (whole iPhone)"))
        #expect(lines.joined().range(of: #"\d[.,]\d\d"#, options: .regularExpression) == nil)
        #expect(Metrics.summary(result).hasSuffix("· Speicher 180 → 215 MB · Netz 12,3 MB WLAN, 0,0 MB mobil"))
        #expect(!Metrics.summary(Self.result()).contains("Netz"))
    }

    @Test func theTwoLatestTestsOfEachViewAreKept() {
        func test(_ source: Metrics.Source, minutes: Double) -> Metrics.TestResult {
            var result = Self.result(notes: [:])
            result.source = source
            result.startedAt = Self.started.addingTimeInterval(minutes * 60)
            return result
        }
        let first = test(.playback, minutes: 0), second = test(.playback, minutes: 5), third = test(.playback, minutes: 9)
        let globe = test(.ownGlobe, minutes: 1)
        var kept = Metrics.TestResult.keeping([], adding: first)
        #expect(kept == [first])
        kept = Metrics.TestResult.keeping(kept + [globe], adding: second)
        #expect(kept == [globe, first, second])
        kept = Metrics.TestResult.keeping(kept, adding: third)
        #expect(kept == [globe, second, third])
        // Stored out of order, the latest still comes last.
        #expect(Metrics.TestResult.keeping([third, second], adding: test(.playback, minutes: 12)).map(\.startedAt)
                == [third.startedAt, Self.started.addingTimeInterval(720)])
        #expect(Metrics.lines(results: kept, altitude: nil).first == "map prototype: tests 3, altitude check no")
    }
}
