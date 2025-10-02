import XCTest
@testable import HypoApp

final class TokenBucketTests: XCTestCase {
    func testConsumeRespectsCapacity() {
        let bucket = TokenBucket(capacity: 1, refillInterval: 1)
        XCTAssertTrue(bucket.consume())
        XCTAssertFalse(bucket.consume())
    }

    func testTokensRefillAfterInterval() throws {
        let bucket = TokenBucket(capacity: 1, refillInterval: 0.1)
        XCTAssertTrue(bucket.consume())
        let expectation = XCTestExpectation(description: "Refill")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            if bucket.consume() {
                expectation.fulfill()
            }
        }
        wait(for: [expectation], timeout: 1)
    }
}
