import Testing
import Foundation
@testable import HypoCore

/// Timestamps as the other platforms actually write them.
@Suite("Pairing timestamps")
struct PairingDateFormatTests {
    @Test("reads what Android sends")
    func readsFractionalSeconds() {
        // Instant.toString() on Android, which carries fractional seconds
        // whenever they are non-zero — nearly always. A plain
        // ISO8601DateFormatter returns nil for this, which broke every pairing
        // handshake that carried an Android timestamp.
        #expect(PairingDateFormat.date(from: "2026-08-30T21:38:41.123456789Z") != nil)
        #expect(PairingDateFormat.date(from: "2026-08-30T21:38:41.123Z") != nil)
    }

    @Test("still reads a timestamp with no fraction")
    func readsWholeSeconds() {
        #expect(PairingDateFormat.date(from: "2026-08-30T21:38:41Z") != nil)
    }

    @Test("what it writes, it can read back")
    func roundTrips() throws {
        let now = Date(timeIntervalSince1970: 1_788_000_000)
        let text = PairingDateFormat.string(from: now)
        let parsed = try #require(PairingDateFormat.date(from: text))
        #expect(abs(parsed.timeIntervalSince(now)) < 1)
    }

    @Test("nonsense is still rejected")
    func rejectsGarbage() {
        #expect(PairingDateFormat.date(from: "not a date") == nil)
        #expect(PairingDateFormat.date(from: "") == nil)
    }
}
