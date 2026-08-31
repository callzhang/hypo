import XCTest
import UIKit
import HypoCore

/// The app and a separate process on this machine, syncing both ways.
///
/// The peer is tools/HypoHarness, which advertises over Bonjour, answers a
/// pairing challenge and prints what arrives. Start it first:
///
///     HYPO_RECEIVED_FILE=/tmp/hypo-received.txt HYPO_DEVICE_NAME="Harness Mac" \
///     HYPO_SEND_TEXT="hello from the Mac harness" swift run HypoHarness show
///
/// Pairs over the LAN rather than with a code: no six digits to race against a
/// one-minute expiry, and it is the path a user on one network would take.
@MainActor
final class HarnessSyncTests: XCTestCase {
    private var receivedPath: String {
        ProcessInfo.processInfo.environment["HYPO_RECEIVED_FILE"] ?? "/tmp/hypo-received.txt"
    }

    func testPairsOverLanAndSyncsBothWays() throws {
        let app = XCUIApplication()
        app.launch()
        addUIInterruptionMonitor(withDescription: "system alerts") { alert in
            for label in ["Allow", "Allow Paste", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
        app.tap()

        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Connection"].waitForExistence(timeout: 10))
        app.buttons["Pair a device"].tap()

        guard app.staticTexts["Harness Mac"].waitForExistence(timeout: 30) else {
            throw XCTSkip("no harness on this network; start HypoHarness to exercise this")
        }
        app.buttons.containing(.staticText, identifier: "Harness Mac").firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["Paired with Harness Mac"].waitForExistence(timeout: 45),
            "pairing over the LAN did not complete"
        )

        // Back to the list. What the harness sends should appear there: a Mac
        // copying something and a phone showing it, which is the app's point.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            app.staticTexts["hello from the Mac harness"].waitForExistence(timeout: 120),
            "the harness's clipboard entry never arrived"
        )

        // And the other direction.
        try? FileManager.default.removeItem(atPath: receivedPath)
        let fromPhone = "copied on the phone \(UUID().uuidString.prefix(8))"
        UIPasteboard.general.string = fromPhone

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()

        // The paste control appears because there is something to send, and
        // reads without a prompt because the user pressed it.
        let paste = app.buttons["Paste"]
        if !paste.waitForExistence(timeout: 15) {
            print("SEND_SCREEN: \(app.staticTexts.allElementsBoundByIndex.map { $0.label })")
            print("SEND_BUTTONS: \(app.buttons.allElementsBoundByIndex.map { $0.label })")
        }
        XCTAssertTrue(paste.exists, "no send control offered")
        paste.tap()

        XCTAssertTrue(
            pollForFile(at: receivedPath, containing: fromPhone, timeout: 90),
            "the phone's clipboard never reached the harness"
        )
    }

    private func pollForFile(at path: String, containing text: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8),
               contents.contains(text) {
                return true
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return false
    }
}
