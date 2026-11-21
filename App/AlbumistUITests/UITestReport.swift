import XCTest
import UIKit

/// The report a UI test leaves in the job log, for test classes without helpers of their own
/// (the flow, search, device and accessibility tests keep theirs): screenshots as
/// `PREVIEW_JPEG ui-…` chunks, from which the run's gallery is built (artifacts cannot be
/// downloaded everywhere), and the accessibility audit's findings as `A11Y_ISSUE` lines, which
/// the report collects without failing the test, as in the flow tests (`AccessibilityUITests`
/// is the run that fails on findings).
@MainActor
enum UITestReport {
    /// What is on screen: kept as an attachment of `test` and printed in chunks.
    static func shot(_ name: String, in test: XCTestCase) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        test.add(attachment)
        let image = screenshot.image
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.5
        let small = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let data = small.jpegData(compressionQuality: 0.55) else { return }
        let text = data.base64EncodedString()
        let size = 4000
        let total = (text.count + size - 1) / size
        var index = 0
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            print("PREVIEW_JPEG ui-\(name) \(index + 1)/\(total) \(text[start..<end])")
            start = end
            index += 1
        }
    }

    /// The accessibility audit of what `app` shows, once the screen is at rest (an audit of a
    /// screen in motion ends the whole test, UI run 43774578089): every finding as an
    /// `A11Y_ISSUE` line, and `A11Y_AUDIT_DONE` at its end.
    static func audit(_ app: XCUIApplication, _ screen: String,
                      file: StaticString = #filePath, line: UInt = #line) {
        UITestWait.screenAtRest(app, "\(screen) at rest before the audit", file: file, line: line)
        UITestOnboarding.clock("audit start \(screen)")
        defer { UITestOnboarding.clock("audit end \(screen)") }
        // An element that changes while the audit reads the screen makes XCTest record "Failed
        // to get matching snapshot". That says nothing about the app, so only that internal
        // error is expected; every other failure still counts.
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        options.issueMatcher = { $0.compactDescription.contains("Failed to get matching snapshot") }
        XCTExpectFailure("The screen changed during the accessibility audit", options: options) {
            do {
                try app.performAccessibilityAudit { issue in
                    let element = issue.element
                    let frame = element.map { f in "\(Int(f.frame.minX)),\(Int(f.frame.minY)) \(Int(f.frame.width))x\(Int(f.frame.height))" } ?? "-"
                    print("A11Y_ISSUE \(screen) | type \(issue.auditType.rawValue) | \(issue.compactDescription) | label '\(element?.label ?? "-")' | \(element?.elementType.rawValue ?? 0) | id '\(element?.identifier ?? "-")' | \(frame)")
                    return true // collect everything, the report decides
                }
                print("A11Y_AUDIT_DONE \(screen)")
            } catch {
                print("A11Y_AUDIT_ERROR \(screen) \(error)")
            }
        }
    }
}
