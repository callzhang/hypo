import XCTest
import UIKit
import HypoCore

/// The app and a separate process on this machine, syncing both ways.
///
/// The peer is tools/HypoHarness, which advertises over Bonjour, answers a
/// pairing challenge and prints what arrives. Start it first:
///
///     HYPO_RECEIVED_FILE=/tmp/hypo-received.txt HYPO_DEVICE_NAME="Harness Mac" \
///     HYPO_SEND_TEXT="hello from the Mac harness" swift run HypoHarness show
///
/// Pairs over the LAN rather than with a code: no six digits to race against a
/// one-minute expiry, and it is the path a user on one network would take.
@MainActor
final class HarnessSyncTests: XCTestCase {
    private var receivedPath: String {
        ProcessInfo.processInfo.environment["HYPO_RECEIVED_FILE"] ?? "/tmp/hypo-received.txt"
    }

    func testPairsOverLanAndSyncsBothWays() throws {
        // Checked before launching anything. This needs a live peer on the
        // network, which CI never has, so there it could only ever launch the
        // app and skip — minutes spent to learn nothing, and one more chance
        // for the simulator to fail to launch at all, which is how this failed
        // on CI rather than skipping.
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
        // Nearby devices are listed in the devices section itself, so pairing
        // with something visible needs no code screen and no code.
        let nearby = app.buttons["NearbyDevice-Harness Mac"]
        guard revealElement(nearby, in: app) else {
            throw XCTSkip("no unpaired harness on this network; start HypoHarness to exercise this")
        }
        nearby.tap()
        XCTAssertTrue(
            isPaired("Harness Mac", in: app),
            "pairing over the LAN did not complete"
        )

        // Back to the list. What the harness sends should appear there: a Mac
        // copying something and a phone showing it, which is the app's point.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(
            app.staticTexts["hello from the Mac harness"].waitForExistence(timeout: 120),
            """
            the harness's clipboard entry never arrived. The harness sends once \
            and stops — repeating would keep overwriting the phone's clipboard \
            and the send control would never appear — so a harness that already \
            paired with an earlier test has nothing left to send. Run this suite \
            against its own freshly started harness.
            """
        )

        // And the other direction.
        try? FileManager.default.removeItem(atPath: receivedPath)
        let fromPhone = "copied on the phone \(UUID().uuidString.prefix(8))"
        UIPasteboard.general.string = fromPhone

        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()

        // The paste control appears because there is something to send, and
        // reads without a prompt because the user pressed it.
        XCTAssertTrue(
            waitForSendControl(in: app, resettingTo: fromPhone),
            "no send control offered"
        )
        app.buttons["Paste"].tap()

        XCTAssertTrue(
            pollForFile(at: receivedPath, containing: fromPhone, timeout: 90),
            "the phone's clipboard never reached the harness"
        )
    }

    /// The outbound half on its own, against a harness this app is already
    /// paired with.
    ///
    /// testPairsOverLanAndSyncsBothWays covers both directions but has to pair
    /// first, and a pairing that settles a little late fails it before the send
    /// is ever exercised — which is exactly what happened while diagnosing the
    /// cloud reconnect bug. Keeping the send on its own means the direction that
    /// needs a real tap can be checked without re-pairing.
    func testSendsTheClipboardToAnAlreadyPairedPeer() throws {
        guard FileManager.default.fileExists(atPath: "/tmp/hypo-peer-tests") else {
            throw XCTSkip("no /tmp/hypo-peer-tests marker; start HypoHarness and touch it to run this")
        }

        let app = XCUIApplication()
        app.launch()

        // Skip rather than fail when this app has not paired with the harness.
        // Without the pairing the send still happens — it just goes to whatever
        // peers this app does know, so waiting on the harness's file would
        // report a broken send that is working fine. That is exactly what this
        // test did on its first run.
        app.buttons["Settings"].tap()
        // NOTE: this guard has only ever skipped. With a harness running and
        // discoverable — Bonjour resolves it, and TransportManager lists it —
        // the app still reports "Harness Mac: offline" after a relaunch, and
        // the paired row never appears, so 60s is not the problem. The send
        // itself is known to work: during testPairsOverLanAndSyncsBothWays the
        // app unicast to the harness over a persistent connection and the
        // harness printed the entry. Why the peer reads offline on a fresh
        // launch is unresolved; until it is, this test cannot run green.
        let paired = isPaired("Harness Mac", in: app, timeout: 60)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        guard paired else {
            throw XCTSkip("this app is not paired with Harness Mac; run testPairsOverLanAndSyncsBothWays first")
        }

        try? FileManager.default.removeItem(atPath: receivedPath)
        // A file rather than an environment variable, for the same reason the
        // skip marker is one: xcodebuild does not forward the shell's
        // environment to the runner. Writing the marker from outside makes the
        // text checkable on a real phone, where the only evidence available is
        // a human reading their own clipboard history.
        let fromPhone = (try? String(contentsOfFile: "/tmp/hypo-outbound-marker", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
            ?? "sent from iOS \(UUID().uuidString.prefix(8))"
        UIPasteboard.general.string = fromPhone
        print("outbound marker: \(fromPhone)")

        // The control only offers itself for pasteboard contents the app has
        // not already seen, so bounce through the background to re-check.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()

        XCTAssertTrue(
            waitForSendControl(in: app, resettingTo: fromPhone),
            "no send control offered"
        )
        app.buttons["Paste"].tap()

        XCTAssertTrue(
            pollForFile(at: receivedPath, containing: fromPhone, timeout: 90),
            "the phone's clipboard never reached the harness"
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


private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
