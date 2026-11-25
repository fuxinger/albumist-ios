/// How a `PhotoCard` sits on the page.
enum PhotoCardStyle: Sendable {
    /// Side by side (a shelf, two in a row; drafts E1, E6): a white card, the title in the
    /// headline style, its actions full width below the text. Every compact card keeps the
    /// height of three text lines, so cards side by side are equally high whatever their texts.
    case compact
    /// Across the page ("Schon gefunden", "Neue Reisen"; drafts E6): a larger title, the action
    /// next to the text while the text keeps room for a long word, below it otherwise and at the
    /// accessibility text sizes.
    case large
    /// An album in a row or a grid (draft E4): the photo with round corners on the page, name
    /// and count below it, no card around them.
    case tile
}
