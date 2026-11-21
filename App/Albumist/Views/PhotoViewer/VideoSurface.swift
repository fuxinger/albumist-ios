import AVFoundation
import SwiftUI
import UIKit

/// The playing video's picture in the photo view (design wave 3, DS-16): Apple's player layer,
/// fitted as the still under it is (`.resizeAspect`, as `scaledToFit`), so the two lie exactly on
/// each other and zoom, move and close together. It draws nothing before its first frame, so the
/// still shows meanwhile: no black flash, no spinner. It takes no touch of its own; the photo
/// view's gestures decide (a tap hides the bars, a double tap zooms, a pull closes), as for a
/// Live Photo's motion (`LivePhotoPlayer`).
struct VideoSurface: UIViewRepresentable {
    var player: ViewerVideo.Player

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.playerLayer?.backgroundColor = UIColor.clear.cgColor
        view.playerLayer?.videoGravity = .resizeAspect
        view.playerLayer?.player = player.value
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer?.player !== player.value { view.playerLayer?.player = player.value }
    }

    /// As large as offered: the video fits itself into it as the still does.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PlayerLayerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    /// The layer lets the player go with the view (the player goes when the video leaves the
    /// screen, `ViewerVideo`).
    static func dismantleUIView(_ view: PlayerLayerView, coordinator: ()) {
        view.playerLayer?.player = nil
    }
}

/// A view whose layer is a player layer.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer? { layer as? AVPlayerLayer }
}
