import Foundation
import Testing
@testable import HypoApp

@Suite("HistoryPersistence")
struct HistoryPersistenceTests {
    @Test("in-memory persistence round-trips data by key")
    func inMemoryRoundTrip() throws {
        let persistence = InMemoryHistoryPersistence()
        let payload = Data("hello".utf8)

        try persistence.setData(payload, forKey: "entries")

        #expect(try persistence.data(forKey: "entries") == payload)
    }

    @Test("reading an unwritten key returns nil")
    func readBeforeWriteIsNil() throws {
        let persistence = InMemoryHistoryPersistence()

        #expect(try persistence.data(forKey: "entries") == nil)
    }

    @Test("removing a key clears it")
    func removeClearsKey() throws {
        let persistence = InMemoryHistoryPersistence()
        try persistence.setData(Data("x".utf8), forKey: "entries")

        try persistence.removeValue(forKey: "entries")

        #expect(try persistence.data(forKey: "entries") == nil)
    }

    @Test("bool flags default to false and round-trip")
    func boolFlagRoundTrip() {
        let persistence = InMemoryHistoryPersistence()

        #expect(persistence.bool(forKey: "migrated") == false)

        persistence.setBool(true, forKey: "migrated")

        #expect(persistence.bool(forKey: "migrated") == true)
    }
}
