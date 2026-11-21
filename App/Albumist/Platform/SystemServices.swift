import CoreLocation
import Foundation
import Network
import UIKit
import AlbumistCore

/// Network reachability for the iCloud rule and to tell "offline" from "throttled".
final class NetworkStatus: @unchecked Sendable {
    static let shared = NetworkStatus()

    private let monitor = NWPathMonitor()
    private let state = LockedBox<(online: Bool, wifi: Bool)>((true, false))

    private init() {
        monitor.pathUpdateHandler = { [state] path in
            let wifi = (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)) && !path.isExpensive
            state.value = (path.status == .satisfied, wifi)
        }
        monitor.start(queue: DispatchQueue(label: "app.albumist.network"))
    }

    var isOnline: Bool { state.value.online }
    var isOnWiFi: Bool { state.value.wifi }
}

/// Reverse geocoding with Apple's geocoder. Results are cached per raster cell by the
/// core, so this is called once per area, not once per photo.
///
/// Note: `CLGeocoder` is deprecated in iOS 26 in favour of `MKReverseGeocodingRequest`.
/// It still works and returns the structured address fields Albumist needs; the migration
/// is tracked in docs/STATUS.md.
struct SystemGeocoder: ReverseGeocoding {
    var locale: Locale

    func reverseGeocode(_ coordinate: GeoCoordinate) async throws -> PlaceComponents? {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location, preferredLocale: locale)
            guard let p = placemarks.first else { return nil }
            return PlaceComponents(
                isoCountryCode: p.isoCountryCode,
                country: p.country,
                administrativeArea: p.administrativeArea,
                subAdministrativeArea: p.subAdministrativeArea,
                locality: p.locality,
                subLocality: p.subLocality,
                thoroughfare: p.thoroughfare,
                areaOfInterest: p.areasOfInterest?.first,
                inlandWater: p.inlandWater,
                ocean: p.ocean,
                timeZoneIdentifier: p.timeZone?.identifier
            )
        } catch let error as CLError {
            switch error.code {
            case .geocodeFoundNoResult, .geocodeFoundPartialResult: return nil
            case .network: throw NetworkStatus.shared.isOnline ? GeocodingError.rateLimited(retryAfter: nil) : GeocodingError.offline
            default: throw GeocodingError.failed
            }
        } catch {
            throw NetworkStatus.shared.isOnline ? GeocodingError.failed : GeocodingError.offline
        }
    }
}

/// Thermal state, Low Power Mode and battery decide whether analysis may continue.
final class DeviceConditions: AnalysisConditions, @unchecked Sendable {
    /// In the background Albumist only works while charging (speed-up 7).
    let isBackgroundRun: Bool

    init(isBackgroundRun: Bool = false) {
        self.isBackgroundRun = isBackgroundRun
    }

    /// The rules live in `DeviceState` (AlbumistCore, tested); this only reads the device.
    func pauseReason() async -> PauseReason? {
        await state().refinementPauseReason
    }

    func pace() async -> AnalysisPace {
        await state().appPace
    }

    /// The battery is read on the main thread at most every few seconds: asked before every
    /// photo, it would otherwise wait for the main thread each time while the UI is busy.
    private func state() async -> DeviceState {
        let info = ProcessInfo.processInfo
        let thermal = DeviceState.Thermal(rawValue: info.thermalState.rawValue) ?? .critical
        HeatLog.note(thermal)
        let battery: (level: Float, charging: Bool)
        if let cached = batteryCache.value, Date().timeIntervalSince(cached.read) < 5 {
            battery = (cached.level, cached.charging)
        } else {
            battery = await MainActor.run { () -> (Float, Bool) in
                UIDevice.current.isBatteryMonitoringEnabled = true
                let state = UIDevice.current.batteryState
                return (UIDevice.current.batteryLevel, state == .charging || state == .full)
            }
            batteryCache.value = (read: Date(), level: battery.level, charging: battery.charging)
        }
        return DeviceState(
            thermal: thermal,
            batteryLevel: battery.level >= 0 ? Double(battery.level) : nil,
            isCharging: battery.charging,
            isLowPowerMode: info.isLowPowerModeEnabled
        )
    }

    private let batteryCache = LockedBox<(read: Date, level: Float, charging: Bool)?>(nil)

    func isOnWiFi() async -> Bool { NetworkStatus.shared.isOnWiFi }
}
