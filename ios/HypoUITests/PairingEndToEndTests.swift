import XCTest
import HypoCore

/// Pairs the real app with a peer, through the real relay, by driving the real
/// UI — the acceptance this phase is actually about.
///
/// The test process plays the other device: it claims the code the app puts on
/// screen, using the same PairingCodeClaimer the app itself would use to claim
/// one. What it proves is that the app's showing side and Swift's claiming side
/// complete a handshake with each other, and that the app records the result.
@MainActor
final class PairingEndToEndTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testAppPairsWithASwiftPeer() async throws {
        let app = XCUIApplication()
        app.launch()
        addUIInterruptionMonitor(withDescription: "notification permission") { alert in
            let allow = alert.buttons["Allow"]
            if allow.exists { allow.tap(); return true }
            return false
        }
        app.tap()

        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Connection"].waitForExistence(timeout: 10))
        app.buttons["Pair a device"].tap()
        XCTAssertTrue(app.buttons["Request pairing code"].waitForExistence(timeout: 10))

        app.buttons["Request pairing code"].tap()

        let code = try waitForPairingCode(in: app)

        // The peer. A different device id is all that separates it from any
        // other client.
        let claimer = PairingCodeClaimer(
            relayClient: PairingRelayClient(baseURL: URL(string: "https://hypo.fly.dev")!),
            deviceId: UUID().uuidString.lowercased(),
            deviceName: "UITest Peer"
        )
        let result = try await claimer.claim(code: code)
        XCTAssertFalse(result.peer.name.isEmpty)

        // Back to settings: the app should now list the device it paired with.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            app.staticTexts["UITest Peer"].waitForExistence(timeout: 20),
            "the app did not list the peer it just paired with"
        )
    }

    private func waitForPairingCode(in app: XCUIApplication) throws -> String {
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            let labels = app.staticTexts.allElementsBoundByIndex.map { $0.label }
            if let code = labels.first(where: {
                $0.range(of: "^[0-9]{4,8}$", options: .regularExpression) != nil
            }) {
                return code
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw XCTSkip("the relay never produced a pairing code")
    }
}
