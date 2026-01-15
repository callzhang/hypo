import Foundation
import Testing
import os

@discardableResult
func waitUntil(
    timeout: Duration = .seconds(1),
    pollInterval: Duration = .milliseconds(10),
    _ condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() {
            return true
        }
        try? await clock.sleep(for: pollInterval)
    }
    return condition()
}

func expectThrows<T>(_ expression: () throws -> T) {
    var didThrow = false
    do {
        _ = try expression()
    } catch {
        didThrow = true
    }
    #expect(didThrow)
}

func expectThrows<T>(_ expression: () async throws -> T) async {
    var didThrow = false
    do {
        _ = try await expression()
    } catch {
        didThrow = true
    }
    #expect(didThrow)
}

func expectApproxEqual(_ lhs: Double, _ rhs: Double, tolerance: Double) {
    #expect(abs(lhs - rhs) <= tolerance)
}

final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock: OSAllocatedUnfairLock<Value>

    init(_ value: Value) {
        self.lock = OSAllocatedUnfairLock(initialState: value)
    }

    func withLock<R: Sendable>(_ body: @Sendable (inout Value) -> R) -> R {
        lock.withLock(body)
    }
}
