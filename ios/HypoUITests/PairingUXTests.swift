import XCTest

/// Checks the pairing screen offers the two ways to pair separately, the way
/// Android does, rather than putting both halves of the choice on one screen.
@MainActor
final class PairingUXTests: XCTestCase {
    private func openPairing() -> XCUIApplication {
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
        return app
    }

    func testOffersLanAndCodeAsSeparateModes() {
        let app = openPairing()

        XCTAssertTrue(app.buttons["LAN"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Code"].exists)

        // LAN is the default: pairing with something already visible should not
        // require typing six digits.
        XCTAssertTrue(
            app.staticTexts["Looking for devices…"].waitForExistence(timeout: 5)
                || app.staticTexts["Nearby devices"].waitForExistence(timeout: 20)
                || app.staticTexts["No devices found"].waitForExistence(timeout: 5),
            "LAN mode showed none of its three states"
        )
    }

    func testCodeModeAsksWhichHalfBeforeShowingEither() {
        let app = openPairing()
        app.buttons["Code"].tap()

        XCTAssertTrue(app.buttons["Show a code"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Enter a code"].exists)
        // Neither flow is on screen until one is chosen — showing both at once
        // is what made this confusing.
        XCTAssertFalse(app.textFields["PairingCodeField"].exists)

        app.buttons["Enter a code"].tap()
        XCTAssertTrue(app.textFields["PairingCodeField"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Show a code"].exists)
    }

    func testLanModeListsADiscoveredPeer() throws {
        let app = openPairing()
        guard app.staticTexts["Nearby devices"].waitForExistence(timeout: 30) else {
            throw XCTSkip("no peer advertising on this network; start HypoHarness to exercise this")
        }
        print("LAN_LIST: \(app.staticTexts.allElementsBoundByIndex.map { $0.label })")
        XCTAssertTrue(app.cells.count > 0 || app.buttons.count > 2)
    }
}
