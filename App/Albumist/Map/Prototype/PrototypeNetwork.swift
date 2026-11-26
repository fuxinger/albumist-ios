import Darwin
import AlbumistMap

/// The iPhone's network counters for the map prototype's 60-second test (concept 2.0 §9,
/// "Mobile Daten": how much Apple's 3D satellite map loads while a trip plays). Read with
/// `getifaddrs`, one entry per link-layer interface: "en…" is Wi-Fi (or a cable), "pdp_ip…" the
/// mobile network; tunnels such as a VPN are left out, as their bytes already go over one of
/// those. Numbers only: no address and no interface name leaves the device.
enum PrototypeNetwork {
    /// Now; `nil` when iOS gives no counters.
    static func counters() -> MapMeasurements.NetworkCounters? {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let head = first else { return nil }
        defer { freeifaddrs(head) }
        var counters = MapMeasurements.NetworkCounters()
        for entry in sequence(first: head, next: { $0.pointee.ifa_next }) {
            let interface = entry.pointee
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
                  let data = interface.ifa_data, let cName = interface.ifa_name else { continue }
            let name = String(cString: cName)
            let kind: MapMeasurements.NetworkCounters.Kind
            if name.hasPrefix("en") { kind = .wifi } else if name.hasPrefix("pdp_ip") { kind = .cellular } else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            counters.interfaces[name] = .init(kind: kind, received: stats.ifi_ibytes, sent: stats.ifi_obytes)
        }
        return counters
    }
}
