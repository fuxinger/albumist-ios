import SortlyCore

/// What the photo info says instead of „Unsortiert“ (review of 18.11., P3-09 follow-up): above
/// „Alben: Familie, Lieblingsfotos“ the status read „Nicht sortiert“. A photo in the user's own
/// albums is unsorted when none of them is an album of the areas that count as sorted for it
/// (`OrganizationStatusResolver.overall`); the status names those areas: „Noch in keinem Album
/// für „Länder und Orte“ oder „Reisen““.
public enum UnsortedReason {
    /// The main areas (`primaryAreas`, „Zählt als sortiert“) that apply to the photo and in which
    /// it is in no album yet, in the order of `OrganizationArea.allCases`: the areas the status
    /// waits for. Empty when it is sorted in each of them or none applies.
    public static func missingAreas(_ state: AssetOrganizationState, primaryAreas: Set<OrganizationArea>) -> [OrganizationArea] {
        OrganizationArea.allCases.filter { area in
            guard primaryAreas.contains(area), let status = state.areas[area] else { return false }
            switch status {
            case .unorganized, .proposed, .pendingConfirmation, .analysisPending: return true
            case .organized, .preExisting, .ignored, .excluded, .analysisImpossible, .notApplicable: return false
            }
        }
    }
}
