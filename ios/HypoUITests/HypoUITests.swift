import XCTest

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

    func testBothTabsOpen() {
        let app = launch()

        XCTAssertTrue(app.staticTexts["History"].waitForExistence(timeout: 10))

        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5))

        app.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["History"].waitForExistence(timeout: 5))
    }

    /// Pairing lives inside Settings, the way it does on Android, rather than
    /// in a tab of its own.
    func testPairingIsReachedFromSettings() {
        let app = launch()
        app.buttons["Settings"].tap()

        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 10))
        app.buttons["Pair a device"].tap()

        XCTAssertTrue(app.staticTexts["Pair a device"].waitForExistence(timeout: 5))
    }

    func testSettingsShowsARealDeviceName() {
        let app = launch()
        app.buttons["Settings"].tap()

        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 10))
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
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 10))
        app.buttons["Pair a device"].tap()
        XCTAssertTrue(app.buttons["Request pairing code"].waitForExistence(timeout: 10))

        app.buttons["Request pairing code"].tap()

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

    func testHistoryOffersASendControl() {
        let app = launch()

        XCTAssertTrue(app.staticTexts["History"].waitForExistence(timeout: 10))
        // The system paste control is how sending is invoked at all.
        XCTAssertTrue(app.buttons["Paste"].waitForExistence(timeout: 5))
    }
}
