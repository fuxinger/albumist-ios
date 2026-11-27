#if targetEnvironment(simulator)
import AVFoundation
import CoreLocation
import ImageIO
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The pictures of the example library (`DemoLibrary`): crops of the simulator's sample photos,
/// rendered screenshots and paper documents, and the short video at home. Drawn off the main
/// actor.
extension DemoLibrary {
    // MARK: Images

    /// Off the main actor: the fetch is a synchronous call to the Photos service, which is
    /// busy with the library being written.
    nonisolated static func sampleImages() async -> [UIImage] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.fetchLimit = 12
        let assets = PHAsset.fetchAssets(with: options)
        var images: [UIImage] = []
        for index in 0..<assets.count {
            if let image = await Self.requestImage(assets.object(at: index).localIdentifier, side: 2400) { images.append(image) }
        }
        return images
    }

    /// The images a batch of the demo library is drawn from (they are only read).
    struct SourceImages: @unchecked Sendable { let images: [UIImage] }

    /// Draws and encodes one batch. Runs off the main actor; returns the generator's state
    /// so the next batch continues the same sequence.
    nonisolated static func items(_ specs: [Spec], sources: SourceImages, firstNumber: Int,
                                  rng start: SeededRandom) -> (items: [Item], rng: SeededRandom) {
        var rng = start
        var number = firstNumber
        var chunk: [Item] = []
        for spec in specs {
            number += 1
            // Each photo's bitmaps (a 1600 × 1200 rendering, its source crop) are freed before
            // the next one; without a pool a batch kept all of them until the task ended.
            autoreleasepool {
                switch spec {
                case let .photo(spot, spread, day):
                    let location = CLLocation(
                        coordinate: CLLocationCoordinate2D(latitude: spot.lat + rng.next(in: -spread...spread),
                                                           longitude: spot.lon + rng.next(in: -spread...spread)),
                        altitude: 0, horizontalAccuracy: 8, verticalAccuracy: 8, timestamp: day)
                    let source = sources.images.isEmpty ? Self.fallbackImage() : sources.images[Int(rng.next(in: 0...999)) % sources.images.count]
                    let image = Self.crop(source, rng: &rng)
                    chunk.append(Item(data: image.jpegData(compressionQuality: 0.85)!, type: .jpeg, name: "IMG_\(number).JPG", date: day, location: location))
                case let .screenshot(lines, day):
                    chunk.append(Item(data: Self.screenshotPNG(lines), type: .png, name: "IMG_\(number).PNG", date: day, location: nil))
                case let .document(lines, day):
                    chunk.append(Item(data: Self.documentPhoto(lines).jpegData(compressionQuality: 0.85)!, type: .jpeg,
                                      name: "IMG_\(number).JPG", date: day, location: nil))
                }
            }
        }
        return (chunk, rng)
    }

    /// A random 50–85 % crop, sometimes mirrored, as a 1600 × 1200 (or portrait) photo.
    nonisolated static func crop(_ source: UIImage, rng: inout SeededRandom) -> UIImage {
        let portrait = rng.next(in: 0...1) < 0.3
        let output = portrait ? CGSize(width: 1200, height: 1600) : CGSize(width: 1600, height: 1200)
        let scale = CGFloat(rng.next(in: 0.5...0.85))
        let w = source.size.width * scale, h = w * output.height / output.width
        let rectH = min(h, source.size.height), rectW = rectH * output.width / output.height
        let x = CGFloat(rng.next(in: 0...Double(max(0, source.size.width - rectW))))
        let y = CGFloat(rng.next(in: 0...Double(max(0, source.size.height - rectH))))
        let mirrored = rng.next(in: 0...1) < 0.4
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: output, format: format).image { ctx in
            if mirrored { ctx.cgContext.translateBy(x: output.width, y: 0); ctx.cgContext.scaleBy(x: -1, y: 1) }
            let factor = output.width / rectW
            source.draw(in: CGRect(x: -x * factor, y: -y * factor, width: source.size.width * factor, height: source.size.height * factor))
        }
    }

    // MARK: Video

    /// Four seconds of 1280 × 720 at 30 frames a second (H.264): a slow pan across one of the
    /// sample photos, so it looks like a filmed moment. Written to a temporary file; nil when
    /// the simulator cannot encode it. Runs off the main actor (`seed`).
    nonisolated static func clip(from sources: SourceImages, seconds: Int = 4) async -> URL? {
        guard let image = sources.images.first?.cgImage else { return nil }
        let size = CGSize(width: 1280, height: 720)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("IMG_2000.MOV")
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return nil }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)
        let rate: Int32 = 30
        let frames = seconds * Int(rate)
        // The photo a little larger than the frame, so it can move from left to right.
        let scale = max(size.width / CGFloat(image.width), size.height / CGFloat(image.height)) * 1.2
        let drawn = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        for frame in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try? await Task.sleep(for: .milliseconds(10))
            }
            guard let pool = adaptor.pixelBufferPool else { break }
            var made: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
            guard let buffer = made else { break }
            let progress = CGFloat(frame) / CGFloat(max(frames - 1, 1))
            let place = CGRect(x: -(drawn.width - size.width) * progress, y: -(drawn.height - size.height) / 2,
                               width: drawn.width, height: drawn.height)
            Self.draw(image, at: place, into: buffer, size: size)
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: rate)) else { break }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    /// One frame of the video: the photo drawn at `place` into the frame's pixels.
    nonisolated private static func draw(_ image: CGImage, at place: CGRect, into buffer: CVPixelBuffer, size: CGSize) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        context.draw(image, in: place)
    }

    nonisolated static func fallbackImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 1200)).image { ctx in
            UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1600, height: 1200))
        }
    }

    /// iPhone-sized screenshot with an EXIF "Screenshot" comment, as iOS writes it.
    nonisolated static func screenshotPNG(_ lines: [String]) -> Data {
        // Looks like a real app screen: status bar, colored header with the title, the
        // details in a list and a button, so previews are recognizable at any crop.
        let size = CGSize(width: 1179, height: 2556)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let palette: [UIColor] = [.systemTeal, .systemIndigo, .systemOrange, .systemPink, .systemGreen, .systemBlue, .systemPurple, .systemRed]
        let light = UITraitCollection(userInterfaceStyle: .light)
        let seed: Int = (lines.first ?? "").unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let accent = palette[seed % palette.count].resolvedColor(with: light)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.systemGroupedBackground.resolvedColor(with: light).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            accent.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: 760))
            let white: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 50, weight: .semibold), .foregroundColor: UIColor.white]
            ("9:41" as NSString).draw(at: CGPoint(x: 110, y: 52), withAttributes: white)
            let title = lines.first ?? ""
            (title as NSString).draw(in: CGRect(x: 72, y: 420, width: size.width - 144, height: 300),
                                     withAttributes: [.font: UIFont.systemFont(ofSize: 104, weight: .bold), .foregroundColor: UIColor.white])
            let details = Array(lines.dropFirst())
            let card = CGRect(x: 48, y: 820, width: size.width - 96, height: CGFloat(details.count) * 170 + 40)
            UIColor.white.setFill()
            UIBezierPath(roundedRect: card, cornerRadius: 44).fill()
            for (i, line) in details.enumerated() {
                let y = card.minY + 20 + CGFloat(i) * 170
                (line as NSString).draw(in: CGRect(x: card.minX + 52, y: y + 50, width: card.width - 104, height: 90),
                                        withAttributes: [.font: UIFont.systemFont(ofSize: 62), .foregroundColor: UIColor.black])
                if i < details.count - 1 {
                    UIColor.separator.resolvedColor(with: light).setFill()
                    ctx.fill(CGRect(x: card.minX + 52, y: y + 169, width: card.width - 52, height: 2))
                }
            }
            let button = CGRect(x: 72, y: 2230, width: size.width - 144, height: 150)
            accent.setFill()
            UIBezierPath(roundedRect: button, cornerRadius: 75).fill()
            let label = "Details anzeigen" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 60, weight: .semibold), .foregroundColor: UIColor.white]
            let labelSize = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: button.midX - labelSize.width / 2, y: button.midY - labelSize.height / 2), withAttributes: attributes)
        }
        let data = NSMutableData()
        guard let cg = image.cgImage,
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return image.pngData()!
        }
        let properties: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Screenshot"]]
        CGImageDestinationAddImage(destination, cg, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    /// A printed page photographed on a table.
    nonisolated static func documentPhoto(_ lines: [String]) -> UIImage {
        let size = CGSize(width: 1500, height: 2000)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(red: 0.55, green: 0.45, blue: 0.36, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let page = CGRect(x: 130, y: 150, width: 1240, height: 1700)
            ctx.cgContext.setShadow(offset: CGSize(width: 0, height: 12), blur: 30, color: UIColor.black.withAlphaComponent(0.4).cgColor)
            UIColor(white: 0.97, alpha: 1).setFill()
            ctx.fill(page)
            ctx.cgContext.setShadow(offset: .zero, blur: 0)
            var y = page.minY + 120
            for (i, line) in lines.enumerated() {
                let font = i == 0 ? UIFont.systemFont(ofSize: 64, weight: .bold) : UIFont.systemFont(ofSize: 44)
                (line as NSString).draw(at: CGPoint(x: page.minX + 100, y: y), withAttributes: [.font: font, .foregroundColor: UIColor.black])
                y += i == 0 ? 160 : 90
            }
        }
    }
}
#endif
