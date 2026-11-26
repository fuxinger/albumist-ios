import XCTest

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

    /// Each audit type alone, timed: which one does not complete (`A11Y_PROBE_AUDIT`).
    static func auditTypesAlone(_ app: XCUIApplication, screen: String) {
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
