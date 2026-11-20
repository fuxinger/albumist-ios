import Foundation
import Testing
import SortlyCore
import SortlyEngine
import SortlyTestSupport

/// The photo info said „Status: Nicht sortiert“ right above „Alben: Familie, Lieblingsfotos“:
/// a photo in the user's own albums is unsorted when none of them is an album of the areas
/// that count as sorted for it (`OrganizationStatusResolver.overall`). The status now names
/// those areas: „Noch in keinem Album für „Länder und Orte“ oder „Reisen““ (`UnsortedReason`).
@Suite("Photo status reason")
struct PhotoStatusReasonTests {
    static let resolver = OrganizationStatusResolver(primaryAreas: [.places, .trips])
    static let id = AssetID("photo")

    static func state(_ areas: [OrganizationArea: AreaStatus]) -> AssetOrganizationState {
        AssetOrganizationState(assetID: id, areas: areas)
    }

    @Test func namesTheMainAreasItIsInNoAlbumOf() {
        let both = Self.state([.places: .unorganized, .trips: .proposed, .imageCategories: .unorganized])
        #expect(UnsortedReason.missingAreas(both, primaryAreas: Self.resolver.primaryAreas) == [.places, .trips])
        let noTrip = Self.state([.places: .unorganized, .trips: .notApplicable])
        #expect(UnsortedReason.missingAreas(noTrip, primaryAreas: Self.resolver.primaryAreas) == [.places])
        let noPlace = Self.state([.places: .analysisImpossible, .trips: .pendingConfirmation])
        #expect(UnsortedReason.missingAreas(noPlace, primaryAreas: Self.resolver.primaryAreas) == [.trips])
    }

    /// The reason is the rule of the status itself: every photo the resolver calls unsorted has at
    /// least one area named, a sorted one none, and every area named is one the status waits for.
    @Test func everyUnsortedPhotoHasItsAreasAndASortedOneNone() {
        let statuses = AreaStatus.allCases
        var unsorted = 0
        for places in statuses {
            for trips in statuses {
                for themes in statuses {
                    let state = Self.state([.places: places, .trips: trips, .imageCategories: themes])
                    let missing = UnsortedReason.missingAreas(state, primaryAreas: Self.resolver.primaryAreas)
                    switch Self.resolver.overall(state) {
                    case .unorganized:
                        unsorted += 1
                        #expect(!missing.isEmpty, "\(places) \(trips)")
                        for area in missing {
                            #expect([.unorganized, .proposed, .pendingConfirmation].contains(state.areas[area]!), "\(area) \(places) \(trips)")
                        }
                    case .fullyOrganized:
                        #expect(missing.isEmpty, "\(places) \(trips): \(missing)")
                    default: break
                    }
                    #expect(!missing.contains(.imageCategories), "not a main area")
                }
            }
        }
        #expect(unsorted > 0)
    }

    /// The photo info says it for an unsorted photo instead of „Unsortiert“.
    @Test func thePhotoInfoNamesTheAreas() throws {
        let library = try AppSource.read("App/Sortly/Views/LibraryView.swift")
        let label = AppSource.code(try #require(AppSource.body(of: "private func statusLabel(", in: library)), keepStrings: true)
        #expect(label.contains("case .unsorted"), "an unsorted photo shows its overall label")
        #expect(label.contains("UnsortedReason.missingAreas("))
        #expect(label.contains("\"Noch in keinem Album für \\("))
    }
}
