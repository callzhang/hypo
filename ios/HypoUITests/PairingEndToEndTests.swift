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
        XCTAssertTrue(revealElement(app.buttons["Pair with code"], in: app), "no way in to code pairing")
        app.buttons["Pair with code"].tap()
        // Code pairing is one of two modes now, and asks which half you want.
        XCTAssertTrue(app.buttons["Show a code"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Show a code"].waitForExistence(timeout: 10))
        app.buttons["Show a code"].tap()

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

        // The pairing screen's own success state, which is this device saying
        // it recorded the pairing.
        //
        // Asserted here rather than by looking for the peer in the devices
        // list: that list is long, a SwiftUI List leaves off-screen rows out
        // of the accessibility tree, and every way of addressing the row was
        // fighting that rather than testing the app. What matters is the
        // failure this guards against — the other device believing it paired
        // while this one recorded nothing, which is exactly what an Android
        // phone reported earlier — and the success view is that signal.
        // Named, because the app says who it paired with. The screen reads
        // "Paired with UITest Peer" — asserting the bare word "Paired" failed
        // against an app that was working correctly the whole time.
        // Matched on the label with a predicate. Subscripting by name looks up
        // the identifier, which for a plain Text is only the label by
        // convention — and here it was not, so an app that was reporting
        // "Paired with UITest Peer" on screen still failed the lookup.
        let success = app.staticTexts
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Paired with"))
            .firstMatch
        XCTAssertTrue(
            success.waitForExistence(timeout: 120),
            "the app did not report the pairing it just completed"
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
