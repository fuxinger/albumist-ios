import XCTest
import UIKit

/// Evidence for an accessibility audit that did not complete twice (A28, 26.11.2026): "en plan
/// lower" timed out in both attempts on the design branch, also after the wait for a calm Mac
/// (load 578 to 403), while it completed on main. The log of that pass held "Geometry action is
/// cycling between duplicate values" (87 times in the English pass's app, never on main): a view
/// that keeps changing gives the audit no still screen. The probe names what changes and which
/// audit type does not complete, so the cause is read from the log, not guessed.
@MainActor
enum UITestScreenProbe {
    /// Snapshots in a row (each takes a moment on a busy Mac, so no pause between them): each
    /// element whose frame, label or value is not the same in all of them (`A11Y_PROBE_MOVING`),
    /// by its place in the tree.
    static func logChanges(_ app: XCUIApplication, screen: String, samples: Int = 5) {
        var seen: [String: Set<String>] = [:]
        var names: [String: String] = [:]
        var taken = 0
        for _ in 0..<samples {
            guard let root = try? app.snapshot() else { continue }
            taken += 1
            var stack: [(node: any XCUIElementSnapshot, path: String)] = [(root, "0")]
            while let (node, path) = stack.popLast() {
                let frame = node.frame
                let state = String(format: "%.0f,%.0f %.0fx%.0f", frame.minX, frame.minY, frame.width, frame.height)
                    + " '\(node.label.prefix(40))' '\(String(describing: node.value ?? "").prefix(20))'"
                seen[path, default: []].insert(state)
                if names[path] == nil {
                    names[path] = "type \(node.elementType.rawValue) id '\(node.identifier)' label '\(node.label.prefix(40))'"
                }
                for (offset, child) in node.children.enumerated() { stack.append((child, path + "." + String(offset))) }
            }
        }
        let moving = seen.filter { $0.value.count > 1 }.sorted { $0.key < $1.key }
        print("A11Y_PROBE \(screen) \(taken) of \(samples) snapshots, \(seen.count) places, \(moving.count) changing")
        for (path, states) in moving.prefix(20) {
            print("A11Y_PROBE_MOVING \(screen) \(path) \(names[path] ?? "") | \(states.sorted().joined(separator: " / "))")
        }
    }

    /// Whether the screen's pixels stand still (A28): the snapshots above compare only the tree,
    /// while the contrast audit reads the pixels. Three screenshots in a row (each takes a
    /// moment, so no pause between them; the time they spanned is logged); the
    /// region whose pixels differ between them, in points (`A11Y_PROBE_PIXELS`). A view that
    /// keeps drawing (a geometry action cycling, a fade that never ends) shows there.
    static func logPixels(_ app: XCUIApplication, screen: String) {
        var shots: [Shot] = []
        let start = Date()
        for _ in 0..<3 {
            let image = XCUIScreen.main.screenshot().image
            guard let cg = image.cgImage, let pixels = rgba(cg) else { continue }
            shots.append(Shot(pixels: pixels, width: cg.width, height: cg.height))
        }
        let span = String(format: "%.1f", Date().timeIntervalSince(start))
        guard let first = shots.first, shots.count == 3,
              shots.allSatisfy({ $0.width == first.width && $0.height == first.height }) else {
            print("A11Y_PROBE_PIXELS \(screen) no comparable screenshots (\(shots.count) of 3)")
            return
        }
        var changed = 0
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for shot in shots.dropFirst() {
            let rowBytes = first.width * 4
            for y in 0..<first.height {
                let row = y * rowBytes
                // Most rows are alike: compared whole first (the test target is built without
                // optimisation, and a pixel loop over a whole screen takes seconds there).
                let alike = first.pixels.withUnsafeBufferPointer { one in
                    shot.pixels.withUnsafeBufferPointer { other in
                        memcmp(one.baseAddress! + row, other.baseAddress! + row, rowBytes) == 0
                    }
                }
                if alike { continue }
                for x in 0..<first.width {
                    let at = row + x * 4
                    guard first.pixels[at] != shot.pixels[at] || first.pixels[at + 1] != shot.pixels[at + 1]
                            || first.pixels[at + 2] != shot.pixels[at + 2] else { continue }
                    changed += 1
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard changed > 0 else {
            print("A11Y_PROBE_PIXELS \(screen) still: 3 screenshots in \(span) s alike")
            return
        }
        // Pixels per point: the screenshot's width over the app's (as the handwriting test reads it).
        let points = app.frame.width
        let scale = points > 0 ? max(CGFloat(first.width) / points, 1) : 1
        let box = String(format: "%.0f,%.0f %.0fx%.0f", CGFloat(minX) / scale, CGFloat(minY) / scale,
                         CGFloat(maxX - minX + 1) / scale, CGFloat(maxY - minY + 1) / scale)
        print("A11Y_PROBE_PIXELS \(screen) changing: \(changed) pixel differences in \(span) s, within \(box) pt")
    }

    /// A screenshot's RGBA bytes, row by row, and its size in pixels.
    private struct Shot {
        let pixels: [UInt8]
        let width: Int
        let height: Int
    }

    /// The image's pixels as RGBA bytes, row by row.
    private static func rgba(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }

    /// Screens whose audit types were already tried alone in this test process.
    private static var probed: Set<String> = []

    /// Each audit type alone, timed: which one does not complete (`A11Y_PROBE_AUDIT`). Once per
    /// test process, for the first screen whose audit failed twice: each type can take up to the
    /// audit's own time limit, so a pass with several such screens would add four audits each to
    /// an already slow pass (UI run 45884483812: the accessibility group's tests took 73 min in
    /// first pass and repeat, against 25-35 min green; its log was lost, so this is a bound, not
    /// a proven cause). Later screens print `A11Y_PROBE_AUDIT … skipped`.
    static func auditTypesAlone(_ app: XCUIApplication, screen: String) {
        guard probed.isEmpty else {
            print("A11Y_PROBE_AUDIT \(screen) skipped (types already tried alone on \(probed.sorted().joined(separator: ", ")))")
            return
        }
        probed.insert(screen)
        let types: [(String, XCUIAccessibilityAuditType)] = [
            ("contrast", .contrast), ("textClipped", .textClipped), ("hitRegion", .hitRegion),
            ("sufficientElementDescription", .sufficientElementDescription)
        ]
        for (name, type) in types {
            let start = Date()
            var outcome = "completed"
            do {
                try app.performAccessibilityAudit(for: type) { _ in true }
            } catch {
                outcome = "did not complete (\(error.localizedDescription))"
            }
            print("A11Y_PROBE_AUDIT \(screen) \(name) \(outcome) after \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        }
    }
}
