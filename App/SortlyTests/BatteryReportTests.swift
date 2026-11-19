import Foundation
import Testing
import SortlyCore
import SortlyEngine
@testable import Sortly

/// The battery line of the diagnostic report ("Akku: 1,8 % pro 1.000 Fotos …", owner
/// 19.11.2026). The numbers and rules are tested on Linux (`BatteryUseTests`); this checks the
/// sentence the app builds and its English.
@Suite("Battery line in the diagnostic report")
@MainActor
struct BatteryReportTests {
    static func stretch(_ place: BatteryStretch.Place, from start: Double, to end: Double, photos: Int) -> BatteryStretch {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        return BatteryStretch(place: place, start: t0, end: t0.addingTimeInterval(1_200), startLevel: start, endLevel: end,
                              charging: false, photos: photos, hottest: 0, lowPower: false)
    }

    @Test func theLineCarriesEveryNumberInTheRegionsFormat() {
        let use = BatteryUse([Self.stretch(.foreground, from: 0.90, to: 0.86, photos: 2_000),
                              Self.stretch(.background, from: 0.80, to: 0.77, photos: 2_500)])
        let line = BatteryLog.line(use, locale: Locale(identifier: "de_DE"))
        // Combined 7 points for 4.500 photos, foreground 2, background 1,2.
        #expect(line.contains("1,6"))
        #expect(line.contains("1,2"))
        #expect(line.contains("4.500"))
        #expect(line.contains("1.000") || line.contains("1,000"))
    }

    @Test func tooLittleSaysWhatWasMeasured() {
        let use = BatteryUse([Self.stretch(.foreground, from: 0.90, to: 0.89, photos: 320)])
        let line = BatteryLog.line(use, locale: Locale(identifier: "de_DE"))
        #expect(line.contains("320"))
        #expect(!line.contains("1.000") && !line.contains("1,000"))
    }

    @Test func englishSentences() throws {
        let path = try #require(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        func english(_ key: String, _ args: String...) -> String {
            String(format: bundle.localizedString(forKey: key, value: nil, table: nil), arguments: args.map { $0 as any CVarArg })
        }
        let places = english("Vordergrund %@, Hintergrund %@", english("%@ %%", "2.1"), english("noch zu wenig gemessen"))
        #expect(places == "foreground 2.1%, background not enough measured yet")
        #expect(english("Akku: %@ pro 1.000 Fotos (%@; %@ Fotos gemessen)", english("unter %@ %%", "0.8"), places, "4,200")
                == "Battery: below 0.8% per 1,000 photos (foreground 2.1%, background not enough measured yet; 4,200 photos measured)")
        #expect(english("Akku: noch zu wenig gemessen (Fotos: %@, verbraucht: %@ %%)", "320", "1")
                == "Battery: not enough measured yet (photos: 320, used: 1%)")
    }
}
