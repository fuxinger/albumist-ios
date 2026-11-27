import Foundation
import Testing
import AlbumistTestSupport

/// Pull down to close beside the pages' swipe (`PhotoViewerSourceTests`, A12).
extension PhotoViewerSourceTests {
    /// A swipe to the next photo belongs to the pages (A12, Build 41: "erst beim 3.–4. Mal"; full
    /// UI run 45873786352, swipe 1: 1 -> 1). Pull down to close is a UIKit pan that begins only
    /// when the way moved is more down than sideways; no SwiftUI drag of the photo takes part in
    /// a touch at normal size.
    @Test func aSidewaysSwipeNeverReachesPullDown() throws {
        let viewer = AppSource.code(try Self.viewer(), keepStrings: true)
        #expect(!viewer.contains(".simultaneousGesture("), "a SwiftUI gesture beside the pages' swipe")
        #expect(viewer.contains(".highPriorityGesture(pan, isEnabled: scale > 1)"))
        let pull = AppSource.code(try Self.file("PullDownToClose.swift"))
        let begin = try #require(AppSource.body(of: "func gestureRecognizerShouldBegin(", in: pull))
        #expect(begin.filter { !$0.isWhitespace }.contains("returnmoved.y>0&&moved.y>abs(moved.x)"), "\(begin)")
        let ended = try #require(AppSource.body(of: "private func pullEnded(", in: viewer))
        #expect(ended.contains("distance > sideways"), "a swipe that ended sideways closes")
    }
}
