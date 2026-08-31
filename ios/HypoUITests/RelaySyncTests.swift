import XCTest
import UIKit

/// The app and a peer that is only reachable through the relay.
///
/// The harness runs with no LAN listener and no Bonjour advertisement, so
/// there is no local route and anything that arrives came over hypo.fly.dev.
/// That is the case the relay exists for: two devices that cannot see each
/// other.
///
///     RELAY_WS_AUTH_TOKEN=… HYPO_CODE_FILE=/tmp/hypo-code.txt \
///     HYPO_RECEIVED_FILE=/tmp/hypo-received.txt HYPO_DEVICE_NAME="Relay Harness" \
///     HYPO_SEND_TEXT="hello over the relay" swift run HypoHarness relay
@MainActor
final class RelaySyncTests: XCTestCase {
    private var codePath: String {
        ProcessInfo.processInfo.environment["HYPO_CODE_FILE"] ?? "/tmp/hypo-code.txt"
    }
    private var receivedPath: String {
        ProcessInfo.processInfo.environment["HYPO_RECEIVED_FILE"] ?? "/tmp/hypo-received.txt"
    }

    func testSyncsThroughTheRelayWithNoLocalRoute() throws {
        guard FileManager.default.fileExists(atPath: codePath) else {
            throw XCTSkip("no pairing code at \(codePath); start HypoHarness in relay mode")
        }

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

        XCTAssertTrue(app.buttons["Code"].waitForExistence(timeout: 10))
        app.buttons["Code"].tap()
        XCTAssertTrue(app.buttons["Enter a code"].waitForExistence(timeout: 10))
        app.buttons["Enter a code"].tap()

        let field = app.textFields["PairingCodeField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        // Read now, not at the start: codes expire in about a minute and
        // launching plus navigating spends most of it.
        let code = try XCTUnwrap(
            try? String(contentsOfFile: codePath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
        field.typeText(code)
        app.buttons["Pair"].tap()

        let paired = app.staticTexts["Paired with Relay Harness"].waitForExistence(timeout: 60)
        if !paired {
            print("RELAY_PAIR_SCREEN: \(app.staticTexts.allElementsBoundByIndex.map { $0.label })")
        }
        XCTAssertTrue(paired, "pairing through the relay did not complete")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            app.staticTexts["hello over the relay"].waitForExistence(timeout: 120),
            "nothing arrived from a peer that is only reachable through the relay"
        )

        try? FileManager.default.removeItem(atPath: receivedPath)
        let fromPhone = "relayed from the phone \(UUID().uuidString.prefix(8))"
        UIPasteboard.general.string = fromPhone

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()

        let paste = app.buttons["Paste"]
        XCTAssertTrue(paste.waitForExistence(timeout: 15), "no send control offered")
        paste.tap()

        XCTAssertTrue(
            pollForFile(at: receivedPath, containing: fromPhone, timeout: 120),
            "the phone's clipboard never reached the relay peer"
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
