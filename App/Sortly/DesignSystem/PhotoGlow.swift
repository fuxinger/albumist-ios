import SwiftUI
import UIKit
import SortlyCore

/// Soft colours taken from one of the user's photos ("Farben aus den Fotos"): every trip and
/// suggestion gets its own gentle colour wash behind it.
@MainActor
enum PhotoPalette {
    private static var cache: [AssetID: [Color]] = [:]

    /// Four colours, one per quarter of the photo (top left, top right, bottom left, bottom
    /// right), slightly richer and kept in a calm brightness range.
    static func colors(for id: AssetID) async -> [Color] {
        if let cached = cache[id] { return cached }
        guard let image = await ThumbnailCache.shared.image(for: id, side: 60), let cg = image.cgImage else { return [] }
        let colors = MainThreadStallWatch.shared.section("photo glow colours") { sample(cg) }
        cache[id] = colors
        return colors
    }

    nonisolated static func sample(_ image: CGImage) -> [Color] {
        let side = 2
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return [] }
        return (0..<(side * side)).map { i in
            let color = UIColor(red: CGFloat(pixels[i * 4]) / 255, green: CGFloat(pixels[i * 4 + 1]) / 255,
                                blue: CGFloat(pixels[i * 4 + 2]) / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            return Color(hue: Double(h), saturation: Double(min(1, s * 1.25)), brightness: Double(min(0.95, max(0.55, b))))
        }
    }
}

/// A colour wash from a photo that fades into the screen background. Decorative only.
struct PhotoGlow: View {
    var id: AssetID?
    @State private var colors: [Color] = []
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            // Text sits on the wash (category, title, count). Reduce Transparency and Increase
            // Contrast both ask for a plain background behind text, so the wash stays off.
            if colors.count == 4 && !reduceTransparency && contrast != .increased {
                // Opaque colours, already mixed with the screen background: XCTest's contrast
                // audit measured text on the see-through wash as if the photo colour were
                // solid, and failed readable text even where the wash had faded to almost
                // nothing ("31 Fotos in Italien.", "Rom und Florenz", UI runs 2-4 and
                // 43773339053). Mixed in advance, what it measures is what is on screen;
                // the bottom row is the background itself, so the wash still fades out.
                // White keeps 9:1 and Theme.secondaryText 4.7:1 on any photo colour.
                MeshGradient(width: 2, height: 3, points: [
                    [0, 0], [1, 0],
                    [0, 0.5], [1, 0.5],
                    [0, 1], [1, 1],
                ], colors: [
                    Theme.background.mix(with: colors[0], by: 0.3), Theme.background.mix(with: colors[1], by: 0.3),
                    Theme.background.mix(with: colors[2], by: 0.09), Theme.background.mix(with: colors[3], by: 0.09),
                    Theme.background, Theme.background,
                ])
                .transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.8), value: colors.count)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: id) {
            guard let id else { return }
            colors = await PhotoPalette.colors(for: id)
        }
    }
}
