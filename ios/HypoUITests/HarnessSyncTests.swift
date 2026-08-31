import XCTest

/// The app pairing with a separate process on this machine, and receiving what
/// that process sends — two real peers, not two halves of one test.
///
/// The peer is tools/HypoHarness, which shows a pairing code, listens on a LAN
/// socket and advertises over Bonjour. Run it first:
///
///     HYPO_CODE_FILE=/tmp/hypo-code.txt HYPO_DEVICE_NAME="Harness Mac" \
///     HYPO_SEND_TEXT="hello from the Mac harness" swift run HypoHarness show
///
/// and point HYPO_CODE_FILE at the same path here. Skipped when that file is
/// absent, so the suite stays runnable without the harness.
@MainActor
final class HarnessSyncTests: XCTestCase {
    private var codePath: String {
        ProcessInfo.processInfo.environment["HYPO_CODE_FILE"] ?? "/tmp/hypo-code.txt"
    }

    func testPairsWithHarnessAndReceivesWhatItSends() throws {
        guard FileManager.default.fileExists(atPath: codePath) else {
            throw XCTSkip("no pairing code at \(codePath); start HypoHarness first")
        }

        let app = XCUIApplication()
        app.launch()
        addUIInterruptionMonitor(withDescription: "system alerts") { alert in
            for label in ["Allow", "OK", "Allow Paste"] where alert.buttons[label].exists {
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

        let field = app.textFields["PairingCodeField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        // Read the code now, not at the start: it expires in about a minute
        // and launching plus navigating spends most of that. The harness
        // reissues, so the file holds whichever code is currently live.
        let code = try XCTUnwrap(
            try? String(contentsOfFile: codePath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        field.typeText(code)
        app.buttons["Enter this code"].tap()

        // The harness answers the challenge as soon as it sees it.
        XCTAssertTrue(
            app.staticTexts["Paired with Harness Mac"].waitForExistence(timeout: 45),
            "pairing with the harness did not complete"
        )

        // Back out to the list, which should now name the harness.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            app.staticTexts["Harness Mac"].waitForExistence(timeout: 20),
            "the harness is not listed as a paired device"
        )

        // And what the harness sends should turn up in history: a Mac copying
        // something and an iPhone showing it, which is the point of the app.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            app.staticTexts["hello from the Mac harness"].waitForExistence(timeout: 90),
            "the harness's clipboard entry never arrived"
        )

        // The other direction: copy on the phone, and the Mac should get it.
        // Sending happens when the app becomes active, so this backgrounds the
        // app and brings it back — what a user does after copying elsewhere.
        guard let receivedPath = ProcessInfo.processInfo.environment["HYPO_RECEIVED_FILE"] else {
            return
        }
        try? FileManager.default.removeItem(atPath: receivedPath)

        let sentFromPhone = "copied on the phone \(UUID().uuidString.prefix(8))"
        UIPasteboard.general.string = sentFromPhone

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()

        // Reading a clipboard this app did not write raises the iOS paste
        // prompt. Interruption monitors only fire when the test interacts with
        // something, so poke the app to give the monitor its chance.
        Thread.sleep(forTimeInterval: 2)
        app.tap()
        for label in ["Allow Paste", "Allow", "Paste"] {
            let button = springboardAlertButton(label)
            if button.exists { button.tap(); break }
        }

        let arrived = pollForFile(at: receivedPath, containing: sentFromPhone, timeout: 90)
        if !arrived {
            // The screen says what the send did — "Sent to 1 device", "No
            // paired devices", or nothing at all if the clipboard read never
            // returned. Cheaper to read than the device log, which does not
            // reliably survive a simulator session.
            print("SEND_SCREEN: \(app.staticTexts.allElementsBoundByIndex.map { $0.label })")
        }
        XCTAssertTrue(arrived, "the phone's clipboard never reached the harness")
    }

    private func springboardAlertButton(_ label: String) -> XCUIElement {
        XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons[label]
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
