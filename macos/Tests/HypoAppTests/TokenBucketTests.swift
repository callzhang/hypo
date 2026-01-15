import Testing
@testable import HypoApp

struct TokenBucketTests {
    @Test
    func testConsumeRespectsCapacity() {
        let bucket = TokenBucket(capacity: 1, refillInterval: 1)
        #expect(bucket.consume())
        #expect(!bucket.consume())
    }

    @Test
    func testTokensRefillAfterInterval() async throws {
        let bucket = TokenBucket(capacity: 1, refillInterval: 0.1)
        #expect(bucket.consume())
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(bucket.consume())
    }
}
