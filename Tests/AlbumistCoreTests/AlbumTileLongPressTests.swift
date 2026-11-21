import Foundation
import Testing
import AlbumistTestSupport

/// The long press on an album's tile (`AlbumTile` in `AlbumTiles.swift`, draft E4): "Fotos
/// ansehen" while the album holds photos, "Rückgängig machen" while Albumist's changes are still
/// in it. The view runs only on a Mac; the guard reads its code.
@Suite("Albums: an album tile's long press")
struct AlbumTileLongPressTests {
    /// An album of the user's without photos and without anything of Albumist's to undo offers
    /// nothing on a long press. Its tile is built without a menu and without a preview of its own,
    /// so nothing lifts: a menu that returns nothing is documented to switch the long press off
    /// only for a view that lifts itself, not beside a preview of its own (review C2 of design
    /// wave 2, N1; the album tiles were the one such case left, handoff of H7 round 3).
    @Test func anEmptyAlbumWithNothingToUndoHasNoLongPress() throws {
        let source = AppSource.code(try AppSource.read("App/Albumist/Views/Albums/AlbumTiles.swift"), keepStrings: true)
        let body = try #require(AppSource.body(of: ["struct AlbumTile", "var body: some View"], in: source), "no AlbumTile.body")
        let squeezed = String(body.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
        // The menu holds something exactly when the album has photos ("Fotos ansehen") or
        // something to undo: only then the tile with menu and preview.
        let offered = try #require(squeezed.range(of: "ifhasPhotos||undoable!=nil{PhotoCard("), "the tile with a menu is built for every album: \(squeezed)")
        let withMenu = squeezed[offered.upperBound...]
        let otherwise = try #require(withMenu.range(of: "}else{PhotoCard("), "no tile without a menu: \(squeezed)")
        #expect(withMenu[..<otherwise.lowerBound].contains("}menu:{"), "the tile with a menu has none")
        #expect(withMenu[..<otherwise.lowerBound].contains("}preview:{"), "the tile with a menu lifts no large album")
        let plain = withMenu[otherwise.upperBound...]
        #expect(!plain.contains("menu:") && !plain.contains("preview:"), "the tile of an album with nothing to offer still has a long press: \(plain)")
        // Both tiles carry the name the UI tests find them by.
        #expect(squeezed.hasSuffix(".accessibilityIdentifier(\"album.tile\")}"), "\(squeezed.suffix(120))")
    }
}
