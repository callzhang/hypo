import XCTest
import UIKit

/// Drives the real app in the simulator.
///
/// This exists because the phase-2 acceptance is about what the app does, not
/// about what its pieces do in isolation, and nothing else here can press a
/// button. `xcrun simctl` has no tap command.
final class HypoUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        // The notification prompt is a system alert; dismiss it if present so
        // it does not sit on top of everything the rest of the test taps.
        addUIInterruptionMonitor(withDescription: "notification permission") { alert in
            let allow = alert.buttons["Allow"]
            if allow.exists { allow.tap(); return true }
            return false
        }
        app.tap()
        return app
    }

    /// One screen with a gear, the way Android works — no tab bar, no title,
    /// no clear-all button.
    func testSettingsOpensFromTheGear() {
        let app = launch()

        XCTAssertTrue(app.textFields["Search"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Clear"].exists)

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Connection"].waitForExistence(timeout: 5))
    }

    /// Pairing is pushed from the devices section of Settings, the way it is
    /// on Android, rather than living in navigation of its own.
    func testPairingIsReachedFromSettings() {
        let app = launch()
        app.buttons["Settings"].tap()

        XCTAssertTrue(app.staticTexts["Connection"].waitForExistence(timeout: 10))
        app.buttons["Pair a device"].tap()

        XCTAssertTrue(app.buttons["Code"].waitForExistence(timeout: 5))
    }

    func testSettingsShowsARealDeviceName() {
        let app = launch()
        app.buttons["Settings"].tap()

        XCTAssertTrue(app.staticTexts["Connection"].waitForExistence(timeout: 10))
        // Assert the row rendered before asserting what is not in it, or the
        // absence check would also pass on a screen that failed to load.
        XCTAssertTrue(app.staticTexts["Name"].waitForExistence(timeout: 5))
        // "localhost" is what ProcessInfo.processInfo.hostName returns on iOS
        // hardware; the app passes UIDevice.current.name instead.
        XCTAssertFalse(app.staticTexts["localhost"].exists)
    }

    /// Probes whether the relay hands out a pairing code at all.
    ///
    /// Not an assertion about the code: this reports what the pairing screen
    /// says after asking, so a relay that refuses is distinguishable from a
    /// button that does nothing.
    func testRequestingAPairingCodeReachesTheRelay() throws {
        let app = launch()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Connection"].waitForExistence(timeout: 10))
        app.buttons["Pair a device"].tap()
        // Code pairing is one of two modes now, and asks which half you want.
        XCTAssertTrue(app.buttons["Code"].waitForExistence(timeout: 10))
        app.buttons["Code"].tap()
        XCTAssertTrue(app.buttons["Show a code"].waitForExistence(timeout: 10))
        app.buttons["Show a code"].tap()

        // Give the round trip room, then read every label on the screen.
        let deadline = Date().addingTimeInterval(20)
        var labels: [String] = []
        while Date() < deadline {
            labels = app.staticTexts.allElementsBoundByIndex.map { $0.label }
            if labels.contains(where: { $0.range(of: "^[0-9]{4,8}$", options: .regularExpression) != nil }) {
                break
            }
            Thread.sleep(forTimeInterval: 1)
        }
        print("PAIRING_SCREEN_LABELS: \(labels)")

        let code = labels.first { $0.range(of: "^[0-9]{4,8}$", options: .regularExpression) != nil }
        XCTAssertNotNil(code, "the relay did not produce a pairing code; screen said: \(labels)")
    }

    /// The send control appears only when there is something to send.
    ///
    /// Detecting that costs no permission prompt; reading does. Showing the
    /// control unconditionally would be a dead button most of the time, and
    /// reading unconditionally would ask the user for permission every single
    /// time they came back to the app.
    func testSendControlFollowsTheClipboard() {
        UIPasteboard.general.items = []

        let app = launch()
        XCTAssertTrue(app.textFields["Search"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Paste"].exists, "offered to send an empty clipboard")

        UIPasteboard.general.string = "something worth sending \(UUID().uuidString.prefix(6))"
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()

        XCTAssertTrue(
            app.buttons["Paste"].waitForExistence(timeout: 10),
            "did not offer to send what was on the clipboard"
        )
    }
}
