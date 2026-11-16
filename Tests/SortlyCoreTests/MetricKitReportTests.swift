import Foundation
import Testing
@testable import SortlyCore

/// MetricKit's hang and crash reports in the diagnostic report (device test 15.11.: hangs on
/// the iPhone could not be traced). The samples follow the JSON of
/// `MXDiagnosticPayload.jsonRepresentation()` / `MXMetricPayload.jsonRepresentation()` as Apple
/// documents it, with values as an iPhone with iOS 26 writes them.
@Suite("MetricKit report")
struct MetricKitReportTests {
    // MARK: Samples

    static let appUUID = "5B4E7C1A-2D3F-3A8B-9C6E-0F1A2B3C4D5E"
    static let kernelUUID = "9A1D2E3F-4B5C-3D6E-8F7A-1B2C3D4E5F60"
    static let swiftUIUUID = "C0FFEE00-1234-3456-89AB-CDEF01234567"
    static let uikitUUID = "D1E2F3A4-B5C6-37D8-9E0F-A1B2C3D4E5F6"

    /// A 3.25 s hang on the main thread (inside Albumist's code, called from SwiftUI) and a
    /// crash (Swift runtime trap on a background thread, with an Objective-C exception
    /// reason and a memory map that names a photo file: both must not be stored).
    static let diagnosticJSON = #"""
    {
      "timeStampBegin" : "2026-11-15 21:04:00 +0000",
      "timeStampEnd" : "2026-11-15 21:04:00 +0000",
      "hangDiagnostics" : [
        {
          "version" : "1.0.0",
          "diagnosticMetaData" : {
            "appBuildVersion" : "57",
            "appVersion" : "0.1.0",
            "regionFormat" : "DE",
            "osVersion" : "iPhone OS 26.1 (23B85)",
            "deviceType" : "iPhone17,3",
            "platformArchitecture" : "arm64e",
            "bundleIdentifier" : "app.albumist.ios",
            "isTestFlightApp" : true,
            "lowPowerModeEnabled" : false,
            "pid" : 1234,
            "hangDuration" : "3.25 sec"
          },
          "callStackTree" : {
            "callStackPerThread" : true,
            "callStacks" : [
              {
                "threadAttributed" : true,
                "callStackRootFrames" : [
                  {
                    "binaryUUID" : "9A1D2E3F-4B5C-3D6E-8F7A-1B2C3D4E5F60",
                    "offsetIntoBinaryTextSegment" : 7124,
                    "sampleCount" : 1,
                    "binaryName" : "libsystem_kernel.dylib",
                    "address" : 7536318420,
                    "subFrames" : [
                      {
                        "binaryUUID" : "5B4E7C1A-2D3F-3A8B-9C6E-0F1A2B3C4D5E",
                        "offsetIntoBinaryTextSegment" : 1193046,
                        "sampleCount" : 1,
                        "binaryName" : "Sortly",
                        "address" : 4296160342,
                        "subFrames" : [
                          {
                            "binaryUUID" : "5B4E7C1A-2D3F-3A8B-9C6E-0F1A2B3C4D5E",
                            "offsetIntoBinaryTextSegment" : 1048592,
                            "sampleCount" : 1,
                            "binaryName" : "Sortly",
                            "address" : 4296015888,
                            "subFrames" : [
                              {
                                "binaryUUID" : "C0FFEE00-1234-3456-89AB-CDEF01234567",
                                "offsetIntoBinaryTextSegment" : 3735928559,
                                "sampleCount" : 1,
                                "binaryName" : "SwiftUI",
                                "address" : 7300000000,
                                "subFrames" : [
                                  {
                                    "binaryUUID" : "D1E2F3A4-B5C6-37D8-9E0F-A1B2C3D4E5F6",
                                    "offsetIntoBinaryTextSegment" : 4660,
                                    "sampleCount" : 1,
                                    "binaryName" : "UIKitCore",
                                    "address" : 7400000000
                                  }
                                ]
                              }
                            ]
                          }
                        ]
                      }
                    ]
                  }
                ]
              },
              {
                "threadAttributed" : false,
                "callStackRootFrames" : [
                  {
                    "binaryUUID" : "9A1D2E3F-4B5C-3D6E-8F7A-1B2C3D4E5F60",
                    "offsetIntoBinaryTextSegment" : 3000,
                    "sampleCount" : 1,
                    "binaryName" : "libsystem_kernel.dylib",
                    "address" : 7536314296
                  }
                ]
              }
            ]
          }
        }
      ],
      "crashDiagnostics" : [
        {
          "version" : "1.0.0",
          "diagnosticMetaData" : {
            "appBuildVersion" : "57",
            "appVersion" : "0.1.0",
            "regionFormat" : "DE",
            "osVersion" : "iPhone OS 26.1 (23B85)",
            "deviceType" : "iPhone17,3",
            "platformArchitecture" : "arm64e",
            "exceptionType" : 6,
            "exceptionCode" : 1,
            "signal" : 5,
            "terminationReason" : "Namespace SIGNAL, Code 5 Trace/BPT trap: 5",
            "virtualMemoryRegionInfo" : "0x16b3c4000 is in mapped file /private/var/mobile/Media/DCIM/100APPLE/IMG_0001.HEIC",
            "exceptionReason" : {
              "composedMessage" : "*** -[NSFileManager attributesOfItemAtPath:] failed for /var/mobile/Media/DCIM/100APPLE/IMG_0001.HEIC",
              "formatString" : "*** -[NSFileManager attributesOfItemAtPath:] failed for %@",
              "arguments" : ["/var/mobile/Media/DCIM/100APPLE/IMG_0001.HEIC"],
              "exceptionType" : "ObjectiveC",
              "className" : "NSException",
              "exceptionName" : "NSInvalidArgumentException"
            }
          },
          "callStackTree" : {
            "callStackPerThread" : true,
            "callStacks" : [
              {
                "threadAttributed" : false,
                "callStackRootFrames" : [
                  {
                    "binaryUUID" : "9A1D2E3F-4B5C-3D6E-8F7A-1B2C3D4E5F60",
                    "offsetIntoBinaryTextSegment" : 7124,
                    "sampleCount" : 1,
                    "binaryName" : "libsystem_kernel.dylib",
                    "address" : 7536318420
                  }
                ]
              },
              {
                "threadAttributed" : true,
                "callStackRootFrames" : [
                  {
                    "binaryUUID" : "5B4E7C1A-2D3F-3A8B-9C6E-0F1A2B3C4D5E",
                    "offsetIntoBinaryTextSegment" : 2236962,
                    "sampleCount" : 1,
                    "binaryName" : "Sortly",
                    "address" : 4297196258
                  }
                ]
              }
            ]
          }
        }
      ]
    }
    """#

    /// A CPU exception: one sampled tree over all threads, branching after the root.
    static let cpuJSON = #"""
    {
      "timeStampBegin" : "2026-11-16 02:00:00 +0000",
      "timeStampEnd" : "2026-11-16 02:00:00 +0000",
      "cpuExceptionDiagnostics" : [
        {
          "version" : "1.0.0",
          "diagnosticMetaData" : {
            "appBuildVersion" : "58",
            "appVersion" : "0.1.0",
            "osVersion" : "iPhone OS 26.1 (23B85)",
            "deviceType" : "iPhone17,3",
            "totalCPUTime" : "90 sec",
            "totalSampledTime" : "180 sec"
          },
          "callStackTree" : {
            "callStackPerThread" : false,
            "callStacks" : [
              {
                "callStackRootFrames" : [
                  {
                    "binaryUUID" : "5B4E7C1A-2D3F-3A8B-9C6E-0F1A2B3C4D5E",
                    "offsetIntoBinaryTextSegment" : 4096,
                    "sampleCount" : 40,
                    "binaryName" : "Sortly",
                    "address" : 4295004160,
                    "subFrames" : [
                      { "binaryUUID" : "5B4E7C1A-2D3F-3A8B-9C6E-0F1A2B3C4D5E", "offsetIntoBinaryTextSegment" : 8192, "sampleCount" : 30, "binaryName" : "Sortly", "address" : 4295008256 },
                      { "binaryUUID" : "D1E2F3A4-B5C6-37D8-9E0F-A1B2C3D4E5F6", "offsetIntoBinaryTextSegment" : 16384, "sampleCount" : 10, "binaryName" : "Vision", "address" : 7600000000 }
                    ]
                  }
                ]
              }
            ]
          }
        }
      ]
    }
    """#

    /// One day of figures.
    static let metricJSON = #"""
    {
      "appVersion" : "0.1.0",
      "timeStampBegin" : "2026-11-14 00:00:00 +0000",
      "timeStampEnd" : "2026-11-14 23:59:00 +0000",
      "metaData" : {
        "appBuildVersion" : "57",
        "osVersion" : "iPhone OS 26.1 (23B85)",
        "regionFormat" : "DE",
        "deviceType" : "iPhone17,3",
        "platformArchitecture" : "arm64e"
      },
      "applicationLaunchMetrics" : {
        "histogrammedTimeToFirstDrawKey" : {
          "histogramNumBuckets" : 3,
          "histogramValue" : {
            "0" : { "bucketCount" : 5, "bucketStart" : "400 ms", "bucketEnd" : "410 ms" },
            "1" : { "bucketCount" : 6, "bucketStart" : "500 ms", "bucketEnd" : "510 ms" },
            "2" : { "bucketCount" : 1, "bucketStart" : "2,000 ms", "bucketEnd" : "2,010 ms" }
          }
        },
        "histogrammedResumeTime" : {
          "histogramNumBuckets" : 1,
          "histogramValue" : { "0" : { "bucketCount" : 20, "bucketStart" : "100 ms", "bucketEnd" : "110 ms" } }
        }
      },
      "applicationResponsivenessMetrics" : {
        "histogrammedAppHangTime" : {
          "histogramNumBuckets" : 2,
          "histogramValue" : {
            "0" : { "bucketCount" : 2, "bucketStart" : "0 ms", "bucketEnd" : "100 ms" },
            "1" : { "bucketCount" : 1, "bucketStart" : "3,000 ms", "bucketEnd" : "3,100 ms" }
          }
        }
      },
      "applicationExitMetrics" : {
        "foregroundExitData" : {
          "cumulativeNormalAppExitCount" : 2,
          "cumulativeAppWatchdogExitCount" : 1,
          "cumulativeMemoryResourceLimitExitCount" : 0
        },
        "backgroundExitData" : {
          "cumulativeSuspendedWithLockedFileExitCount" : 0,
          "cumulativeBackgroundTaskAssertionTimeoutExitCount" : 1,
          "cumulativeMemoryPressureExitCount" : 3
        }
      },
      "memoryMetrics" : {
        "peakMemoryUsage" : "412,000 kB",
        "averageSuspendedMemory" : { "averageValue" : "90,000 kB", "standardDeviation" : 0, "sampleCount" : 20 }
      },
      "cpuMetrics" : { "cumulativeCPUTime" : "1,800 sec" },
      "diskIOMetrics" : { "cumulativeLogicalWrites" : "120,000 kB" }
    }
    """#

    let hangDate = Date(timeIntervalSince1970: 1_794_776_640) // 2026-11-15T21:04:00Z
    let cpuDate = Date(timeIntervalSince1970: 1_794_794_400) // 2026-11-16T02:00:00Z
    let dayDate = Date(timeIntervalSince1970: 1_794_700_740) // 2026-11-14T23:59:00Z

    func temporaryArchive(_ limits: MetricKitArchive.Limits = .init()) -> MetricKitArchive {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("metrickit-\(UUID().uuidString)", isDirectory: true)
        return MetricKitArchive(directory: folder, limits: limits)
    }

    func data(_ text: String) -> Data { Data(text.utf8) }

    func reportText(_ archive: MetricKitArchive, options: MetricKitReport.Options = .init()) -> String {
        MetricKitReport.lines(archive.payloads(), options: options).joined(separator: "\n")
    }

    /// A diagnostic payload of a given size with a distinct content (for the limits).
    func filler(_ index: Int, bytes: Int = 200) -> Data {
        data(#"{"hangDiagnostics":[{"diagnosticMetaData":{"hangDuration":"\#(index) sec","pad":"\#(String(repeating: "x", count: bytes))"}}]}"#)
    }

    // MARK: Archive

    @Test func storesAndReadsBackNewestFirst() throws {
        let archive = temporaryArchive()
        defer { archive.removeAll() }
        #expect(archive.save(data(Self.metricJSON), kind: .metric, date: dayDate) == .saved)
        #expect(archive.save(data(Self.cpuJSON), kind: .diagnostic, date: cpuDate) == .saved)
        #expect(archive.save(data(Self.diagnosticJSON), kind: .diagnostic, date: hangDate) == .saved)
        let payloads = archive.payloads()
        #expect(payloads.map(\.date) == [cpuDate, hangDate, dayDate])
        #expect(payloads.map(\.kind) == [.diagnostic, .diagnostic, .metric])
    }

    @Test func removesTextsThatCouldNameAFileBeforeStoring() throws {
        let archive = temporaryArchive()
        defer { archive.removeAll() }
        archive.save(data(Self.diagnosticJSON), kind: .diagnostic, date: hangDate)
        let stored = try #require(archive.payloads().first)
        let text = try #require(String(data: stored.json, encoding: .utf8))
        #expect(!text.contains("IMG_0001"))
        #expect(!text.contains("/var/mobile"))
        #expect(!text.contains("composedMessage"))
        #expect(!text.contains("virtualMemoryRegionInfo"))
        // What tells the crash apart stays.
        #expect(text.contains("NSInvalidArgumentException"))
        #expect(text.contains("failed for %@"))
        #expect(text.contains("hangDuration"))
        // Also on disk, not only in what is read back.
        for name in try FileManager.default.contentsOfDirectory(atPath: archive.directory.path) {
            let raw = try String(contentsOf: archive.directory.appendingPathComponent(name), encoding: .utf8)
            #expect(!raw.contains("IMG_0001"))
        }
    }

    @Test func thePayloadIOSHandsOverAgainIsStoredOnce() {
        let archive = temporaryArchive()
        defer { archive.removeAll() }
        #expect(archive.save(data(Self.diagnosticJSON), kind: .diagnostic, date: hangDate) == .saved)
        #expect(archive.save(data(Self.diagnosticJSON), kind: .diagnostic, date: hangDate) == .duplicate)
        #expect(archive.payloads().count == 1)
    }

    @Test func keepsTheNewestOfEachKindAndDropsTheOldest() {
        let archive = temporaryArchive(.init(diagnostics: 3, metrics: 2, totalBytes: 1_000_000, payloadBytes: 100_000))
        defer { archive.removeAll() }
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        // Out of order: the date counts, not when it arrived.
        for index in [4, 0, 2, 5, 1, 3] {
            archive.save(filler(index), kind: .diagnostic, date: base.addingTimeInterval(Double(index) * 60))
        }
        for day in 0..<4 {
            archive.save(data(Self.metricJSON.replacingOccurrences(of: "412,000", with: "41\(day),000")), kind: .metric,
                         date: base.addingTimeInterval(Double(day) * 86_400))
        }
        let payloads = archive.payloads()
        let diagnostics = payloads.filter { $0.kind == .diagnostic }.map(\.date)
        #expect(diagnostics == [5, 4, 3].map { base.addingTimeInterval(Double($0) * 60) })
        let metrics = payloads.filter { $0.kind == .metric }.map(\.date)
        #expect(metrics == [3, 2].map { base.addingTimeInterval(Double($0) * 86_400) })
    }

    @Test func staysUnderTheTotalSize() throws {
        let archive = temporaryArchive(.init(diagnostics: 100, metrics: 100, totalBytes: 5_000, payloadBytes: 2_000))
        defer { archive.removeAll() }
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        for index in 0..<10 { archive.save(filler(index, bytes: 1_000), kind: .diagnostic, date: base.addingTimeInterval(Double(index))) }
        var total = 0
        for name in try FileManager.default.contentsOfDirectory(atPath: archive.directory.path) {
            total += try Data(contentsOf: archive.directory.appendingPathComponent(name)).count
        }
        #expect(total <= 5_000)
        let kept = archive.payloads().map(\.date)
        #expect(kept.count == 4)
        #expect(kept.first == base.addingTimeInterval(9))
    }

    @Test func anOversizedCrashKeepsOnlyItsCrashedThread() throws {
        // Many threads: too large as a whole, small enough with the crashed thread alone.
        var object = try #require(MetricKitArchive.object(data(Self.diagnosticJSON)))
        var crashes = try #require(object["crashDiagnostics"] as? [[String: Any]])
        var tree = try #require(crashes[0]["callStackTree"] as? [String: Any])
        var stacks = try #require(tree["callStacks"] as? [[String: Any]])
        let idle = stacks[0]
        stacks += Array(repeating: idle, count: 200)
        tree["callStacks"] = stacks
        crashes[0]["callStackTree"] = tree
        object["crashDiagnostics"] = crashes
        object.removeValue(forKey: "hangDiagnostics")
        let big = try JSONSerialization.data(withJSONObject: object)
        let archive = temporaryArchive(.init(payloadBytes: 8_000))
        defer { archive.removeAll() }
        #expect(big.count > 8_000)
        #expect(archive.save(big, kind: .diagnostic, date: hangDate) == .saved)
        let first = try #require(archive.payloads().first)
        let stored = try #require(MetricKitArchive.object(first.json))
        let storedTree = try #require((stored["crashDiagnostics"] as? [[String: Any]])?.first?["callStackTree"] as? [String: Any])
        let kept = try #require(storedTree["callStacks"] as? [[String: Any]])
        #expect(kept.count == 1)
        #expect(kept[0]["threadAttributed"] as? Bool == true)
    }

    @Test func rejectsWhatIsNoPayload() {
        let archive = temporaryArchive(.init(payloadBytes: 1_000))
        defer { archive.removeAll() }
        #expect(archive.save(data("not json"), kind: .diagnostic, date: hangDate) == .rejected)
        #expect(archive.save(data("[1, 2]"), kind: .diagnostic, date: hangDate) == .rejected)
        #expect(archive.save(filler(1, bytes: 5_000), kind: .diagnostic, date: hangDate) == .rejected)
        #expect(archive.payloads().isEmpty)
    }

    @Test func fileNamesCarryKindAndDate() throws {
        let name = MetricKitArchive.fileName(kind: .metric, date: dayDate, hash: "00ff00ff00ff00ff")
        #expect(name == "metric-001794700740000-00ff00ff00ff00ff.json")
        let parsed = try #require(MetricKitArchive.parse(name))
        #expect(parsed.kind == .metric)
        #expect(parsed.date == dayDate)
        #expect(MetricKitArchive.parse("notes.txt") == nil)
        #expect(MetricKitArchive.parse("other-1-2.json") == nil)
    }

    // MARK: Report

    @Test func aHangReadsWithWhenVersionDurationAndStack() {
        let archive = temporaryArchive()
        defer { archive.removeAll() }
        archive.save(data(Self.diagnosticJSON), kind: .diagnostic, date: hangDate)
        let lines = MetricKitReport.lines(archive.payloads())
        #expect(lines[0] == "MetricKit (reports from iOS about this app, kept on this device): 1 diagnostic, 0 daily")
        let hang = lines.firstIndex { $0.hasPrefix("hang ") }
        #expect(hang != nil)
        guard let hang else { return }
        #expect(lines[hang] == "hang 2026-11-15T21:04:00Z, app 0.1.0 (57), iPhone OS 26.1 (23B85), iPhone17,3, duration 3.25 sec")
        #expect(lines[hang + 1] == "  thread 0 of 2, the one it happened on:")
        #expect(lines[hang + 2] == "    0 libsystem_kernel.dylib +0x1bd4")
        #expect(lines[hang + 3] == "    1 Sortly +0x123456")
        #expect(lines[hang + 4] == "    2 Sortly +0x100010")
        #expect(lines[hang + 5] == "    3 SwiftUI +0xdeadbeef")
        #expect(lines[hang + 6] == "    4 UIKitCore +0x1234")
        #expect(lines[hang + 7] == "  binaries: libsystem_kernel.dylib \(Self.kernelUUID); Sortly \(Self.appUUID); "
                + "SwiftUI \(Self.swiftUIUUID); UIKitCore \(Self.uikitUUID)")
    }

    @Test func aCrashReadsWithExceptionSignalAndNoFileName() {
        let archive = temporaryArchive()
        defer { archive.removeAll() }
        archive.save(data(Self.diagnosticJSON), kind: .diagnostic, date: hangDate)
        let lines = MetricKitReport.lines(archive.payloads())
        let crash = lines.firstIndex { $0.hasPrefix("crash ") }
        #expect(crash != nil)
        guard let crash else { return }
        #expect(lines[crash] == "crash 2026-11-15T21:04:00Z, app 0.1.0 (57), iPhone OS 26.1 (23B85), iPhone17,3, EXC_BREAKPOINT (SIGTRAP), code 1, "
                + "termination Namespace SIGNAL, Code 5 Trace/BPT trap: 5, "
                + "NSInvalidArgumentException [NSException]: *** -[NSFileManager attributesOfItemAtPath:] failed for %@")
        // The crashed thread is the second one.
        #expect(lines[crash + 1] == "  thread 1 of 2, the one it happened on:")
        #expect(lines[crash + 2] == "    0 Sortly +0x222222")
        // Crashes come before hangs in the same payload.
        #expect(crash < (lines.firstIndex { $0.hasPrefix("hang ") } ?? 0))
        let all = lines.joined(separator: "\n")
        #expect(!all.contains("IMG_0001"))
        #expect(!all.contains("/var/mobile"))
    }

    @Test func aSampledTreeShowsSamplesAndBranches() {
        let archive = temporaryArchive()
        defer { archive.removeAll() }
        archive.save(data(Self.cpuJSON), kind: .diagnostic, date: cpuDate)
        let lines = MetricKitReport.lines(archive.payloads())
        let cpu = lines.firstIndex { $0.hasPrefix("cpu exception ") }
        #expect(cpu != nil)
        guard let cpu else { return }
        #expect(lines[cpu] == "cpu exception 2026-11-16T02:00:00Z, app 0.1.0 (58), iPhone OS 26.1 (23B85), iPhone17,3, cpu 90 sec in 180 sec sampled")
        #expect(lines[cpu + 1] == "  sampled stacks (frame ×samples):")
        #expect(lines[cpu + 2] == "    0 Sortly +0x1000 ×40")
        #expect(lines[cpu + 3] == "      1 Sortly +0x2000 ×30")
        #expect(lines[cpu + 4] == "      2 Vision +0x4000 ×10")
    }

    @Test func longStacksAreCutAndSaySo() {
        let archive = temporaryArchive()
        defer { archive.removeAll() }
        archive.save(data(Self.diagnosticJSON), kind: .diagnostic, date: hangDate)
        let lines = MetricKitReport.lines(archive.payloads(), options: .init(frames: 2))
        let hang = lines.firstIndex { $0.hasPrefix("hang ") } ?? 0
        #expect(lines[hang + 2] == "    0 libsystem_kernel.dylib +0x1bd4")
        #expect(lines[hang + 3] == "    1 Sortly +0x123456")
        #expect(lines[hang + 4] == "    … 3 more frames in the JSON below")
        // Only the binaries of the frames shown.
        #expect(lines[hang + 5] == "  binaries: libsystem_kernel.dylib \(Self.kernelUUID); Sortly \(Self.appUUID)")
    }

    @Test func dailyFiguresInOneLine() {
        let archive = temporaryArchive()
        defer { archive.removeAll() }
        archive.save(data(Self.metricJSON), kind: .metric, date: dayDate)
        let line = MetricKitReport.lines(archive.payloads()).first { $0.hasPrefix("daily ") }
        #expect(line == "daily 2026-11-14 00:00:00 +0000 – 2026-11-14 23:59:00 +0000, app 0.1.0 (57), iPhone OS 26.1 (23B85), iPhone17,3, "
                + "launch to first draw 12 (median 500 ms–510 ms, slowest 2,000 ms–2,010 ms), "
                + "resume 20 (median 100 ms–110 ms, slowest 100 ms–110 ms), "
                + "hangs 3 (median 0 ms–100 ms, slowest 3,000 ms–3,100 ms), "
                + "exits on screen: app watchdog 1, normal app 2, "
                + "exits in background: background task assertion timeout 1, memory pressure 3, "
                + "peak memory 412,000 kB, cpu 1,800 sec, disk writes 120,000 kB")
    }

    @Test func theCleanedJSONFollowsForTools() throws {
        let archive = temporaryArchive()
        defer { archive.removeAll() }
        archive.save(data(Self.diagnosticJSON), kind: .diagnostic, date: hangDate)
        archive.save(data(Self.cpuJSON), kind: .diagnostic, date: cpuDate)
        let lines = MetricKitReport.lines(archive.payloads())
        let start = try #require(lines.firstIndex(of: "MetricKit JSON (cleaned, one payload per line, newest first)"))
        #expect(lines[start + 1].hasPrefix("diagnostic 2026-11-16T02:00:00Z {"))
        #expect(lines[start + 2].hasPrefix("diagnostic 2026-11-15T21:04:00Z {"))
        // Each JSON line parses again (for a symbolication script).
        let json = String(lines[start + 2].split(separator: " ", maxSplits: 2)[2])
        let object = try #require(MetricKitArchive.object(Data(json.utf8)))
        #expect(object["hangDiagnostics"] != nil)
        // Over the budget: the older payload is left out and the report says so.
        let small = MetricKitReport.lines(archive.payloads(), options: .init(jsonBytes: 3_000))
        let smallStart = try #require(small.firstIndex(of: "MetricKit JSON (cleaned, one payload per line, newest first)"))
        #expect(small[smallStart + 1].hasPrefix("diagnostic 2026-11-16T02:00:00Z {"))
        #expect(small[smallStart + 2] == "(1 older payloads left out for size; they stay on the device)")
    }

    @Test func nothingStoredYet() {
        let lines = MetricKitReport.lines([])
        #expect(lines == [
            "MetricKit (reports from iOS about this app, kept on this device): 0 diagnostic, 0 daily",
            "  none yet: iOS hands them over at the next launch after a hang or crash, daily figures once a day",
        ])
    }

    @Test func unknownValuesStayReadable() {
        #expect(MetricKitReport.machException(99) == "exception 99")
        #expect(MetricKitReport.signalName(31) == "signal 31")
        #expect(MetricKitReport.exitName("cumulativeAppWatchdogExitCount") == "app watchdog")
        #expect(MetricKitReport.exitName("somethingNew") == "something new")
        let lines = MetricKitReport.diagnosticLines(["crashDiagnostics": [["diagnosticMetaData": [String: Any]()]]], date: hangDate, options: .init())
        #expect(lines == ["crash 2026-11-15T21:04:00Z, app ? (?), no exception type"])
    }
}
