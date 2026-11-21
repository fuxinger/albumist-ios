import Foundation

// What went over the network during a test of `MapMeasurements`, from the iPhone's counters.

extension MapMeasurements {
    // MARK: - Data over the network

    /// The iPhone's network counters at one moment (concept §9, "Mobile Daten"): per interface the
    /// bytes received and sent since its connection came up. iOS keeps them in 32 bits, so they
    /// wrap after 4 GiB. They count the whole iPhone, not only Albumist: a fair test has nothing
    /// else loading. The interface names stay on the device; the report gets the sums only.
    public struct NetworkCounters: Hashable, Sendable {
        /// By interface name ("en0" is Wi-Fi, "pdp_ip0" the mobile network).
        public var interfaces: [String: Interface]

        public init(interfaces: [String: Interface] = [:]) {
            self.interfaces = interfaces
        }
    }

    /// What went over the network during a test, in bytes, both directions together.
    public struct NetworkUse: Hashable, Sendable, Codable {
        public var wifiBytes: UInt64
        public var cellularBytes: UInt64

        public init(wifiBytes: UInt64 = 0, cellularBytes: UInt64 = 0) {
            self.wifiBytes = wifiBytes
            self.cellularBytes = cellularBytes
        }

        /// Megabytes of a million bytes, as iOS counts them in its settings.
        public var wifiMB: Double { Double(wifiBytes) / 1_000_000 }
        public var cellularMB: Double { Double(cellularBytes) / 1_000_000 }
    }

    /// Adds up the network use of a test from readings of the counters taken about every half
    /// second, interface by interface. A counter that went down between two readings either
    /// wrapped past 4 GiB (then the difference counts modulo 2^32) or started again from zero
    /// because its connection came back (then its new value counts); more than
    /// `plausibleBytesPerReading` since the last reading means the latter. An interface that comes
    /// up during the test counts from zero; one that goes away adds nothing more.
    public struct NetworkLog: Sendable {
        /// 256 MB in about half a second is beyond any iPhone's network (4 Gbit/s).
        public static let plausibleBytesPerReading: UInt32 = 256_000_000

        private var last: NetworkCounters?
        public private(set) var use = NetworkUse()
        public private(set) var readings = 0

        public init() {}

        public mutating func add(_ reading: NetworkCounters) {
            readings += 1
            defer { last = reading }
            guard let last else { return }
            for (name, now) in reading.interfaces {
                let before = last.interfaces[name].flatMap { $0.kind == now.kind ? $0 : nil }
                let bytes = Self.bytes(from: before?.received, to: now.received) + Self.bytes(from: before?.sent, to: now.sent)
                switch now.kind {
                case .wifi: use.wifiBytes += bytes
                case .cellular: use.cellularBytes += bytes
                }
            }
        }

        /// The use since the first reading; `nil` until there are two readings.
        public var result: NetworkUse? { readings >= 2 ? use : nil }

        /// The bytes between two values of one counter (`old` is `nil` for a new interface).
        static func bytes(from old: UInt32?, to new: UInt32) -> UInt64 {
            if let old {
                let difference = new &- old
                if difference <= plausibleBytesPerReading { return UInt64(difference) }
            }
            return new <= plausibleBytesPerReading ? UInt64(new) : 0
        }
    }
}

extension MapMeasurements.NetworkCounters {
    /// Which network an interface is on.
    public enum Kind: Hashable, Sendable { case wifi, cellular }

    /// One interface's counters: its kind, and the bytes received and sent since its connection
    /// came up.
    public struct Interface: Hashable, Sendable {
        public var kind: Kind
        public var received: UInt32
        public var sent: UInt32

        public init(kind: Kind, received: UInt32, sent: UInt32) {
            self.kind = kind
            self.received = received
            self.sent = sent
        }
    }
}
