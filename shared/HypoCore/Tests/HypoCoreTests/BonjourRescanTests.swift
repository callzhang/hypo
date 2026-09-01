import Foundation
import Testing
@testable import HypoCore

@MainActor
struct BonjourRescanTests {
    /// Bonjour announces a service once. A device whose app was opened while nobody
    /// was browsing will not announce itself again just because someone opened the
    /// pairing panel, so the panel has to ask.
    @Test
    func testRescanRestartsTheBrowse() async {
        let driver = MockBonjourDriver()
        let browser = BonjourBrowser(driver: driver)
        await browser.start()
        #expect(driver.startCount == 1)
        #expect(driver.restartCount == 0)

        await browser.rescan()
        #expect(driver.restartCount == 1)
        // Restarting is not starting a second browse.
        #expect(driver.startCount == 1)

        await browser.stop()
    }

    @Test
    func testRescanStartsBrowsingIfItNeverStarted() async {
        let driver = MockBonjourDriver()
        let browser = BonjourBrowser(driver: driver)

        await browser.rescan()
        #expect(driver.startCount == 1)
        #expect(driver.restartCount == 0)

        await browser.stop()
    }
}
