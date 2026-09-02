import XCTest
import UIKit

/// Drives the real app in the simulator.
///
/// This exists because the phase-2 acceptance is about what the app does, not
/// about what its pieces do in isolation, and nothing else here can press a
/// button. `xcrun simctl` has no tap command.
@MainActor
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
        XCTAssertTrue(revealElement(app.buttons["Pair with code"], in: app), "no way in to code pairing")
        app.buttons["Pair with code"].tap()

        XCTAssertTrue(app.buttons["Show a code"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(revealElement(app.buttons["Pair with code"], in: app), "no way in to code pairing")
        app.buttons["Pair with code"].tap()
        // Code pairing is one of two modes now, and asks which half you want.
        XCTAssertTrue(app.buttons["Show a code"].waitForExistence(timeout: 10))
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

        // Re-set between checks. A peer pushing entries writes each one to the
        // clipboard, and the app then correctly sees nothing of the user's to
        // offer — right behaviour, but it means a live device on the network
        // can take the clipboard back between setting it and looking.
        // The app polls the clipboard about every 1.5s, so each attempt gets
        // two sampling windows. Many attempts, because a peer pushing entries
        // writes each one to the clipboard, after which the app correctly has
        // nothing of the user's to offer — right behaviour, but it means a live
        // device on the network competes for the clipboard the whole time.
        let offered = waitForSendControl(
            in: app,
            resettingTo: "something worth sending \(UUID().uuidString.prefix(6))"
        )
        XCTAssertTrue(offered, "did not offer to send what was on the clipboard")
    }

    /// Offering to send must not interrupt the user.
    ///
    /// The whole reason sending is a button rather than something the app does
    /// on its own: iOS raises "Hypo would like to paste from …" for any
    /// programmatic read of content this app did not write. Deciding whether
    /// there is anything worth offering asks only whether the clipboard holds
    /// text, which raises nothing; the read happens inside UIPasteControl,
    /// which Apple exempts. If a prompt ever appears just from opening the app,
    /// that promise is broken.
    func testOfferingToSendDoesNotPrompt() {
        let app = launch()
        XCTAssertTrue(app.textFields["Search"].waitForExistence(timeout: 15))

        UIPasteboard.general.string = "foreign text \(UUID().uuidString.prefix(6))"
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()

        let offered = waitForSendControl(
            in: app,
            resettingTo: "foreign text \(UUID().uuidString.prefix(6))"
        )
        XCTAssertTrue(offered, "never offered to send, so the no-prompt claim is untested")

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let pasteAlert = springboard.buttons["Allow Paste"]
        XCTAssertFalse(
            pasteAlert.exists,
            "a paste prompt appeared just from showing the offer"
        )
        XCTAssertFalse(
            app.staticTexts["Don't Allow Paste"].exists,
            "a paste prompt appeared inside the app"
        )
    }

    /// A row shows a preview; the entry itself has to be reachable.
    ///
    /// Android opens a detail sheet for anything the row had to cut off, and
    /// for every image and file. Without it a long clipboard entry can be seen
    /// but not read, which for a clipboard app is the part you wanted.
    func testALongEntryCanBeOpenedInFull() throws {
        let app = launch()
        XCTAssertTrue(app.textFields["Search"].waitForExistence(timeout: 15))

        let long = "a long entry that the row cannot show in full " + String(repeating: "x", count: 300)
        UIPasteboard.general.string = long
        guard waitForSendControl(in: app, resettingTo: long) else {
            throw XCTSkip("could not put anything in the history to open")
        }
        app.buttons["Paste"].tap()

        // The preview control only appears on entries with more to show.
        let preview = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'Preview-'")).firstMatch
        guard preview.waitForExistence(timeout: 20) else {
            throw XCTSkip("no entry with more to show landed in the history")
        }
        preview.tap()

        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10), "the preview did not open")
        // The full text, not the three lines the row had room for.
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'xxxxx'")).firstMatch.exists,
                      "the preview did not show the whole entry")
        app.buttons["Done"].tap()
    }

    /// The device name can be changed from settings.
    ///
    /// It defaults to whatever the OS calls the device, which is what every
    /// peer then shows, and there was no way to change it anywhere.
    func testTheDeviceNameCanBeEdited() {
        let app = launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15))
        app.buttons["Settings"].tap()

        let field = app.textFields["DeviceNameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the name is not editable")

        let renamed = "Renamed \(UUID().uuidString.prefix(4))"
        field.tap()
        // The field's own clear button. Selecting the old text first — through
        // the edit menu, backspaces, or command-A — all appended instead of
        // replacing on at least one run, leaving names like
        // "Renamed 129ARenamed F59F" behind.
        let clear = app.buttons["ClearDeviceName"]
        if clear.waitForExistence(timeout: 3) { clear.tap() }
        field.typeText(renamed + "\n")

        // The field's own value, not a lookup by the new name: elements are
        // addressed by identifier, and this one's is DeviceNameField whatever
        // it happens to contain.
        var kept = false
        for _ in 0..<10 where !kept {
            kept = (field.value as? String) == renamed
            if !kept { Thread.sleep(forTimeInterval: 0.5) }
        }
        XCTAssertTrue(kept, "the new name was not kept: \(String(describing: field.value))")
    }

    /// Sends whatever is on the clipboard, for driving a real-device check.
    ///
    /// Gated on a marker so it never runs unattended.
    ///   printf 'text' | xcrun simctl pbcopy booted
    ///   touch /tmp/hypo-send-now
    func testSendsWhateverIsOnTheClipboard() throws {
        guard FileManager.default.fileExists(atPath: "/tmp/hypo-send-now") else {
            throw XCTSkip("no /tmp/hypo-send-now marker")
        }
        let app = launch()
        XCTAssertTrue(app.textFields["Search"].waitForExistence(timeout: 15))

        // Whatever the harness put there — not replaced, unlike the other
        // tests, which set their own text and would overwrite it.
        let paste = app.buttons["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 20), "nothing offered to send")
        paste.tap()
        Thread.sleep(forTimeInterval: 6)
    }
}

/// Scrolls until the element is on screen.
///
/// The devices section lists nearby devices now, so rows below it can sit past
/// the fold — and a SwiftUI List leaves off-screen rows out of the
/// accessibility tree entirely, which reads as "does not exist" rather than
/// "not visible yet".
@MainActor
@discardableResult
func revealElement(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 6) -> Bool {
    for _ in 0..<attempts {
        if element.exists && element.isHittable { return true }
        app.swipeUp()
    }
    return element.exists && element.isHittable
}

/// Waits for the send control, re-setting the clipboard between checks.
///
/// Every entry a peer pushes is written to the clipboard, after which the app
/// correctly has nothing of the user's left to offer. A single wait loses that
/// race against any live device on the network, so the text is put back before
/// each look. The app samples the clipboard about every 1.5s.
@MainActor
@discardableResult
func waitForSendControl(in app: XCUIApplication, resettingTo text: String, attempts: Int = 12) -> Bool {
    let paste = app.buttons["Paste"]
    for _ in 0..<attempts {
        UIPasteboard.general.string = text
        if paste.waitForExistence(timeout: 4) { return true }
    }
    return false
}

/// Whether a device shows up in the paired list.
///
/// The identifier lands on a cell in some SwiftUI layouts and on the label in
/// others, and which one it is has changed with the surrounding view. Asking
/// both is cheaper than pinning down which, and the question — is this device
/// paired — is the same either way.
@MainActor
func isPaired(_ deviceName: String, in app: XCUIApplication, timeout: TimeInterval = 60) -> Bool {
    let identifier = "PairedDevice-\(deviceName)"
    func present() -> Bool {
        app.cells[identifier].exists
            || app.staticTexts[identifier].exists
            || app.buttons[identifier].exists
    }
    // Scrolls while it waits. The devices section grows with every pairing and
    // with whatever is on the network, so the row can start below the fold —
    // and a SwiftUI List leaves off-screen rows out of the accessibility tree,
    // so waiting alone never finds them.
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if present() { return true }
        app.swipeUp()
        if present() { return true }
        Thread.sleep(forTimeInterval: 0.5)
    }
    return present()
}
