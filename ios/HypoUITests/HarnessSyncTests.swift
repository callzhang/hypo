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
        guard let code = try? String(contentsOfFile: codePath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty else {
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
    }
}
