import Foundation

@main
enum LatencyBudgetTests {
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { self.lock.withLock { self.value = true } }
        var isSet: Bool { self.lock.withLock { self.value } }
    }

    static func main() async throws {
        // A result inside the budget wins.
        let fast = try await LatencyBudget.run(milliseconds: 500) {
            try await Task.sleep(nanoseconds: 10_000_000)
            return "cleaned"
        }
        precondition(fast == "cleaned")

        // A slow operation is cut off at the budget and cancelled.
        let cancelled = Flag()
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await LatencyBudget.run(milliseconds: 100) { () async throws -> String in
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    cancelled.set()
                    throw error
                }
                return "late"
            }
            preconditionFailure("expected budget to be exceeded")
        } catch let error as LatencyBudget.Exceeded {
            precondition(error == LatencyBudget.Exceeded(milliseconds: 100))
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        precondition(elapsed < 0.5, "budget returned after \(elapsed)s")
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(cancelled.isSet, "late operation was not cancelled")

        // The caller is not held up by an operation that ignores cancellation.
        let stubbornStarted = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await LatencyBudget.run(milliseconds: 50) { () async throws -> String in
                let deadline = ProcessInfo.processInfo.systemUptime + 0.4
                while ProcessInfo.processInfo.systemUptime < deadline {
                    await Task.yield()
                }
                return "ignored"
            }
            preconditionFailure("expected budget to be exceeded")
        } catch is LatencyBudget.Exceeded {}
        precondition(ProcessInfo.processInfo.systemUptime - stubbornStarted < 0.3)

        // Errors from the operation pass through unchanged.
        struct Boom: Error {}
        do {
            _ = try await LatencyBudget.run(milliseconds: 500) { () async throws -> String in throw Boom() }
            preconditionFailure("expected Boom")
        } catch is Boom {}

        // Zero disables the budget.
        let unlimited = try await LatencyBudget.run(milliseconds: 0) {
            try await Task.sleep(nanoseconds: 20_000_000)
            return 7
        }
        precondition(unlimited == 7)

        // Cancelling the caller cancels the race.
        let outer = Task {
            try await LatencyBudget.run(milliseconds: 5000) { () async throws -> Int in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return 1
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        outer.cancel()
        do {
            _ = try await outer.value
            preconditionFailure("expected cancellation")
        } catch is CancellationError {}

        precondition(LatencyBudget.clamp(0) == LatencyBudget.millisecondsRange.lowerBound)
        precondition(LatencyBudget.clamp(800) == 800)
        precondition(LatencyBudget.clamp(60_000) == LatencyBudget.millisecondsRange.upperBound)

        print("LatencyBudgetTests passed")
    }
}
