import Foundation
import Testing
@testable import AlbumistCore
import AlbumistTestSupport

/// Drag to select and the swipes back in the shared grid (`PhotoGridSourceTests`).
extension PhotoGridSourceTests {
    /// The scroll view's pan and the swipe back over the content (iOS 26's
    /// `interactiveContentPopGestureRecognizer`) wait for the drag to select; the drag waits for
    /// the swipe back from the screen's edge (review L7). UI run 45603459548: a sideways drag over
    /// a trip's photos went back, as the content's swipe back was taken for the edge's by its
    /// class alone (`isEdgeSwipeBack`).
    @Test func theSwipesBackAndTheDrag() throws {
        let waits = Self.squeezed(try Self.body(["final class PhotoGridSelectRecognizer", "shouldBeRequiredToFailBy"], in: Self.recognizers))
        // A UI run's record of the swipes back (`markSwipeBack`) only after the answer.
        #expect(waits.hasPrefix("{letwaits=otherGestureRecognizer!==self&&(otherGestureRecognizerisUIPanGestureRecognizer"
                                + "||otherGestureRecognizer===swipesBack().content)&&!isEdgeSwipeBack(otherGestureRecognizer)"), "\(waits)")
        #expect(waits.hasSuffix("returnwaits}"), "\(waits)")
        // The swipe back from the screen's edge is never taken: the pan waits for it (review L7).
        let edge = Self.squeezed(try Self.body(["final class PhotoGridSelectRecognizer", "shouldRequireFailureOf"], in: Self.recognizers))
        #expect(edge.hasPrefix("{letedge=isEdgeSwipeBack(otherGestureRecognizer)") && edge.hasSuffix("returnedge}"), "\(edge)")
        let isEdge = Self.squeezed(try Self.body(["final class PhotoGridSelectRecognizer", "private func isEdgeSwipeBack("],
                                                 in: Self.recognizers))
        #expect(isEdge == "{letpops=swipesBack()ifother===pops.edge{returntrue}"
                          + "returnotherisUIScreenEdgePanGestureRecognizer&&other!==pops.content}", "\(isEdge)")
        let pops = Self.squeezed(try Self.body(["final class PhotoGridSelectRecognizer", "private func swipesBack("], in: Self.recognizers))
        #expect(pops.contains("letnavigation=controller.navigationController{return(navigation.interactivePopGestureRecognizer,"
                              + "navigation.interactiveContentPopGestureRecognizer)}"), "\(pops)")
    }
}
