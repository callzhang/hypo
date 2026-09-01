import Testing
import Foundation
@testable import HypoCore

@Suite("Bonjour TXT record parsing")
struct TXTRecordParsingTests {
    private func record(_ entries: [String]) -> Data {
        var data = Data()
        for entry in entries {
            let bytes = Data(entry.utf8)
            data.append(UInt8(bytes.count))
            data.append(bytes)
        }
        return data
    }

    @Test("key=value pairs come through")
    func parsesPairs() {
        let parsed = NetServiceBonjourBrowsingDriver.parseTXTRecord(
            record(["device_id=abc123", "version=1.0.0"])
        )
        #expect(parsed["device_id"] == "abc123")
        #expect(parsed["version"] == "1.0.0")
    }

    @Test("a key with no value does not crash the process")
    func toleratesValuelessKey() {
        // Foundation represents this as NSNull, and bridging the dictionary it
        // returns to [String: Data] aborts. An iPhone died on resolving a peer
        // that advertised an empty field.
        let parsed = NetServiceBonjourBrowsingDriver.parseTXTRecord(
            record(["device_id=abc123", "fingerprint", "version=1.0.0"])
        )
        #expect(parsed["fingerprint"] == "")
        #expect(parsed["device_id"] == "abc123")
        #expect(parsed["version"] == "1.0.0")
    }

    @Test("an empty value is kept as empty, not dropped")
    func keepsEmptyValue() {
        let parsed = NetServiceBonjourBrowsingDriver.parseTXTRecord(record(["fingerprint="]))
        #expect(parsed["fingerprint"] == "")
    }

    @Test("a value containing = keeps everything after the first one")
    func splitsOnFirstSeparator() {
        let parsed = NetServiceBonjourBrowsingDriver.parseTXTRecord(record(["pub_key=AA==BB"]))
        #expect(parsed["pub_key"] == "AA==BB")
    }

    @Test("a truncated record stops rather than reading past the end")
    func toleratesTruncation() {
        var data = record(["device_id=abc"])
        data.append(UInt8(40))  // claims 40 more bytes that are not there
        let parsed = NetServiceBonjourBrowsingDriver.parseTXTRecord(data)
        #expect(parsed["device_id"] == "abc")
    }
}
