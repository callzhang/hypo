import Foundation

public final class TokenBucket {
    private let capacity: Double
    private let refillRatePerSecond: Double
    private var tokens: Double
    private var lastRefill: TimeInterval
    private let lock = NSLock()

    init(capacity: Int, refillInterval: TimeInterval) {
        precondition(capacity > 0, "Capacity must be positive")
        precondition(refillInterval > 0, "Refill interval must be positive")
        self.capacity = Double(capacity)
        self.tokens = Double(capacity)
        self.refillRatePerSecond = Double(capacity) / refillInterval
        self.lastRefill = Date().timeIntervalSince1970
    }

    func consume() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        refillTokensLocked(currentTime: Date().timeIntervalSince1970)
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }

    func consume(allowing count: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        refillTokensLocked(currentTime: Date().timeIntervalSince1970)
        guard tokens >= Double(count) else { return false }
        tokens -= Double(count)
        return true
    }

    private func refillTokensLocked(currentTime: TimeInterval) {
        let elapsed = currentTime - lastRefill
        guard elapsed > 0 else { return }
        let newTokens = elapsed * refillRatePerSecond
        tokens = min(capacity, tokens + newTokens)
        lastRefill = currentTime
    }
}

extension TokenBucket {
    public static func clipboardThrottle(interval: TimeInterval = 0.3) -> TokenBucket {
        TokenBucket(capacity: 1, refillInterval: interval)
    }
}
