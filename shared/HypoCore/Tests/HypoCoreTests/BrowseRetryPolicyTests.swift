import Foundation
import Testing
@testable import HypoCore

struct BrowseRetryPolicyTests {
    @Test
    func testBacksOffAndThenHoldsSteady() {
        let policy = BrowseRetryPolicy(initialDelay: 1, maximumDelay: 30)
        #expect(policy.delay(forAttempt: 1) == 1)
        #expect(policy.delay(forAttempt: 2) == 2)
        #expect(policy.delay(forAttempt: 3) == 4)
        #expect(policy.delay(forAttempt: 5) == 16)
        // Capped: a Mac left running overnight should still be checking every 30s,
        // not once a fortnight.
        #expect(policy.delay(forAttempt: 6) == 30)
        #expect(policy.delay(forAttempt: 40) == 30)
    }

    @Test
    func testFirstAttemptIsNeverZero() {
        let policy = BrowseRetryPolicy(initialDelay: 2, maximumDelay: 30)
        #expect(policy.delay(forAttempt: 0) == 2)
        #expect(policy.delay(forAttempt: -1) == 2)
    }
}
