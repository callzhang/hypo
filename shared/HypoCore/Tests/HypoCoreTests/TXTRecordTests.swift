import Foundation
import Testing
@testable import HypoCore

struct TXTRecordTests {
    @Test
    func testParsesKeyValuePairs() {
        let data = makeRecord(["device_id=abc123", "pub_key=cHVia2V5"])
        let parsed = TXTRecord.parse(data)
        #expect(parsed == ["device_id": "abc123", "pub_key": "cHVia2V5"])
    }

    /// The entry that crashed the app: a bare key with no value is legal DNS-SD,
    /// and `NetService.dictionary(fromTXTRecord:)` aborts the process on it.
    @Test
    func testParsesAValuelessKey() {
        let data = makeRecord(["device_id=abc123", "legacy", "port=7010"])
        let parsed = TXTRecord.parse(data)
        #expect(parsed["legacy"] == "")
        #expect(parsed["device_id"] == "abc123")
        #expect(parsed["port"] == "7010")
    }

    @Test
    func testKeepsAnEmptyValueDistinctFromAMissingKey() {
        let parsed = TXTRecord.parse(makeRecord(["fingerprint="]))
        #expect(parsed["fingerprint"] == "")
        #expect(parsed["absent"] == nil)
    }

    @Test
    func testMatchesTheSystemEncoderForOrdinaryRecords() throws {
        // Round-trip against what the publisher actually puts on the wire.
        let source = ["device_id": "abc123", "pub_key": "cHVia2V5", "version": "1.0"]
        let encoded = NetService.data(fromTXTRecord: source.mapValues { Data($0.utf8) })
        #expect(TXTRecord.parse(encoded) == source)
    }

    @Test
    func testTruncatedRecordKeepsWhatParsedCleanly() {
        var data = makeRecord(["device_id=abc123"])
        data.append(contentsOf: [40, UInt8(ascii: "x")]) // claims 40 bytes, supplies one
        let parsed = TXTRecord.parse(data)
        #expect(parsed == ["device_id": "abc123"])
    }

    @Test
    func testEmptyRecordIsEmpty() {
        #expect(TXTRecord.parse(Data()).isEmpty)
    }

    private func makeRecord(_ entries: [String]) -> Data {
        var data = Data()
        for entry in entries {
            let bytes = Array(entry.utf8)
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        return data
    }
}
