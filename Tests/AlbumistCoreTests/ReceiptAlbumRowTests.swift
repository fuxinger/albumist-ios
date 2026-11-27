import Foundation
import Testing
import AlbumistTestSupport

/// What a row of the receipt "Änderungen" says beside its album (`ReceiptAlbumRow` in
/// `PlanReceiptView`). The view runs only on a Mac; the guard reads its code.
@Suite("Change receipt: an album's row")
struct ReceiptAlbumRowTests {
    static func row() throws -> String {
        let source = try AppSource.read("App/Albumist/Views/PlanReceiptView.swift")
        let row = try #require(AppSource.body(of: "private struct ReceiptAlbumRow", in: source), "no ReceiptAlbumRow")
        return AppSource.code(row, keepStrings: true)
    }

    /// A new album says "Neu" and how many photos it holds, "16 Fotos", as the preview says it
    /// before (`PlanReviewView`): "+16 Fotos" beside "Neu" read as photos added to an album that
    /// was there (screenshots of UI run 44852630315, polish list point 3). Photos added to an
    /// album that was there keep their "+", photos taken out their "−".
    @Test func aNewAlbumSaysHowManyPhotosItHolds() throws {
        let row = try Self.row()
        let unsigned = #"Text("\(album.added) \(album.added.formatted()) Fotos")"#
        let signed = #"Text("+\(album.added) \(album.added.formatted()) Fotos")"#
        let at = try #require(row.range(of: unsigned), "a new album does not say its count without a sign")
        #expect(row[..<at.lowerBound].suffix(160).contains("if album.change == .created {"),
                "the count without a sign is not for a new album only")
        #expect(row.contains(signed), "photos added to an album that was there lost their \"+\"")
        #expect(row.contains(#"Text("−\(album.removed) \(album.removed.formatted()) Fotos")"#))
    }
}
