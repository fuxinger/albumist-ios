import XCTest
import UIKit

/// The counts the locked tests read: a row's number and the free albums left in Settings (SwiftLint's file length).
extension AlbumistLockedUITests {
    /// The number of a row made of a title and a number, maybe with a word after it: the plan's
    /// summary (PlanReviewView.row, combined into one element: "Neue Alben, 3") or Settings'
    /// "Noch kostenlos" (LabeledContent: "1 Alben" as the element's value, or combined). Should
    /// the two come as elements of their own, the number is the text on the title's line. nil
    /// when no such row is there within `timeout`.
    func rowCount(_ title: String, timeout: TimeInterval) -> Int? {
        func number(_ text: some StringProtocol) -> Int? {
            let plain = text.replacingOccurrences(of: ".", with: "")
            guard let m = plain.wholeMatch(of: #/[,:\s]*(\d+)(?:\s+\p{L}+)?\s*/#) else { return nil }
            return Int(m.1)
        }
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title))
        if timeout > 0 { _ = rows.firstMatch.waitForExistence(timeout: timeout) }
        var titleFrame: CGRect?
        for row in rows.allElementsBoundByIndex {
            guard let snapshot = try? row.snapshot() else { continue }
            if let n = number(snapshot.label.dropFirst(title.count)) { return n }
            if snapshot.label == title {
                if let value = snapshot.value as? String, let n = number(value) { return n }
                titleFrame = snapshot.frame
            }
        }
        guard let line = titleFrame else { return nil }
        for text in app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[0-9.]+( \\p{L}+)?")).allElementsBoundByIndex {
            guard let snapshot = try? text.snapshot(), snapshot.frame.midY >= line.minY, snapshot.frame.midY <= line.maxY,
                  snapshot.frame.minX > line.maxX, let n = number(snapshot.label) else { continue }
            return n
        }
        return nil
    }

    /// "Noch kostenlos: N Alben" in Settings (SettingsView, section "Vollversion"), opened from
    /// the start page and closed again. nil when it cannot be read.
    func freeAlbumsLeftInSettings() -> Int? {
        guard tap(app.buttons["Einstellungen"], "settings for the free albums (locked)") else { return nil }
        UITestWait.appears(app.navigationBars["Einstellungen"], "settings open for the free albums (locked)", timeout: 10)
        let row = anything("Noch kostenlos")
        var swipes = 0
        while !(row.exists && row.isHittable) && swipes < 10 {
            app.swipeUp()
            swipes += 1
        }
        let left = rowCount("Noch kostenlos", timeout: 5)
        print("UI_FACT locked: Settings says \(left.map { "\($0)" } ?? "?") free albums left")
        shot("72-locked-free-albums")
        tap(button("Fertig"), "close settings after the free albums (locked)")
        UITestWait.disappears(app.navigationBars["Einstellungen"], "settings closed after the free albums (locked)", timeout: 20)
        return left
    }
}
