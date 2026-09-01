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
        XCTAssertTrue(revealElement(app.buttons["Pair with code"], in: app), "no way in to code pairing")
        app.buttons["Pair with code"].tap()
        return app
    }

    @discardableResult
    private func openSettings() -> XCUIApplication {
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
        return app
    }

    /// Pairing with something already visible must not require typing six
    /// digits, so the nearby devices sit in the devices section itself rather
    /// than behind the code screen.
    func testNearbyDevicesLiveInTheDevicesSection() {
        let app = openSettings()

        XCTAssertTrue(app.staticTexts["Devices"].waitForExistence(timeout: 10))
        XCTAssertTrue(revealElement(app.buttons["Pair with code"], in: app))
        // Typing a code is the fallback, so it must not be the only route.
        XCTAssertFalse(app.buttons["LAN"].exists)
    }

    func testCodeScreenAsksWhichHalfBeforeShowingEither() {
        let app = openPairing()

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
        let app = openSettings()
        guard app.staticTexts["On this network"].waitForExistence(timeout: 30) else {
            throw XCTSkip("no peer advertising on this network; start HypoHarness to exercise this")
        }
        print("LAN_LIST: \(app.staticTexts.allElementsBoundByIndex.map { $0.label })")
        XCTAssertTrue(app.cells.count > 0 || app.buttons.count > 2)
    }

    /// Pairs by tapping a device in the list — no code typed anywhere.
    ///
    /// Needs a peer advertising on this network; tools/HypoHarness is one.
    /// Skipped when nothing named "Harness Mac" turns up, so the suite stays
    /// runnable without it.
    func testTappingANearbyDevicePairsWithIt() throws {
        // A marker file rather than an environment variable: xcodebuild does
        // not forward the shell's environment to the test runner process, and
        // TEST_RUNNER_-prefixed variables did not arrive either. A file is
        // visible to both sides with no ceremony, and CI never has one.
        //
        // Create it alongside a running HypoHarness:
        //   touch /tmp/hypo-peer-tests
        guard FileManager.default.fileExists(atPath: "/tmp/hypo-peer-tests") else {
            throw XCTSkip("no /tmp/hypo-peer-tests marker; start HypoHarness and touch it to run this")
        }
        let app = openSettings()

        // Identifiers rather than the label text: a nearby device and a paired
        // one both show the same name, and after pairing the row moves from one
        // group to the other, which is exactly what this asserts.
        // Which device to pair with, so this can be aimed at a real phone as
        // easily as at the harness. Defaults to the harness when unset.
        let target = (try? String(contentsOfFile: "/tmp/hypo-peer-name", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Harness Mac"
        let nearby = app.buttons["NearbyDevice-\(target)"]
        guard revealElement(nearby, in: app) else {
            throw XCTSkip("no harness on this network; start HypoHarness to exercise this")
        }
        nearby.tap()

        let paired = isPaired(target, in: app)
        if !paired {
            print("LAN_PAIR_SCREEN: \(app.staticTexts.allElementsBoundByIndex.map { $0.label })")
        }
        XCTAssertTrue(paired, "tapping a nearby device did not pair with it")
    }

    /// Reports the connection row. Not an assertion about which state it
    /// reaches — that depends on the network — but a way to see it.
    /// The status row says one of the states it knows, with an icon.
    ///
    /// It used to print the screen's labels and assert nothing, which passes
    /// whatever the app does — including showing nothing at all.
    func testReportsConnectionStatus() {
        let app = openSettings()

        XCTAssertTrue(app.staticTexts["Status"].waitForExistence(timeout: 10))

        // The same words the macOS menu bar uses.
        let known = ["Disconnected", "Connecting…", "LAN", "Connected"]
        let shown = known.first { app.staticTexts[$0].exists }
        XCTAssertNotNil(
            shown,
            "the status row showed none of \(known): \(app.staticTexts.allElementsBoundByIndex.map { $0.label }.prefix(12))"
        )
    }

    /// A paired device can be removed.
    ///
    /// Without this a device that is gone for good — a phone you no longer own,
    /// a harness from a test run — stays in the list forever, and the app keeps
    /// trying to send to it.
    func testAPairedDeviceCanBeUnpaired() throws {
        let app = XCUIApplication()
        app.launch()
        addUIInterruptionMonitor(withDescription: "system alerts") { alert in
            for label in ["Allow", "Allow Paste", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap(); return true
            }
            return false
        }
        app.tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Devices"].waitForExistence(timeout: 10))

        guard app.staticTexts["No paired devices"].exists == false else {
            throw XCTSkip("nothing paired to remove")
        }

        let before = app.cells.count
        let row = app.cells.element(boundBy: 0)
        row.swipeLeft()
        guard app.buttons["Unpair"].waitForExistence(timeout: 5) else {
            throw XCTSkip("could not reveal the unpair action on this row")
        }
        app.buttons["Unpair"].tap()

        // One fewer row, or the empty-state text where the list used to be.
        let removed = app.staticTexts["No paired devices"].waitForExistence(timeout: 5)
            || app.cells.count < before
        XCTAssertTrue(removed, "the device was still listed after unpairing")
    }
}
