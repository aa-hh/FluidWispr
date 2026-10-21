@testable import FluidVoice_Debug
import Foundation
import XCTest

// LatencyBudget races a real operation against a real timer, so these tests wait on the
// wall clock by design; the budgets are small and the bounds are generous.
final class LatencyBudgetTests: XCTestCase {
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { self.lock.withLock { self.value = true } }
        var isSet: Bool { self.lock.withLock { self.value } }
    }

    private struct Boom: Error {}

    // Turns red if a result that arrives inside the budget is dropped or replaced.
    func testResultInsideBudgetWins() async throws {
        let fast = try await LatencyBudget.run(milliseconds: 500) {
            try await Task.sleep(nanoseconds: 10_000_000) // real-time-ok: operation shorter than the budget
            return "cleaned"
        }
        XCTAssertEqual(fast, "cleaned")
    }

    // Turns red if a slow operation is not cut off at the budget or is left running.
    func testSlowOperationIsCutOffAndCancelled() async throws {
        let cancelled = Flag()
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await LatencyBudget.run(milliseconds: 100) { () async throws -> String in
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000) // real-time-ok: operation that outlives the budget
                } catch {
                    cancelled.set()
                    throw error
                }
                return "late"
            }
            XCTFail("expected budget to be exceeded")
        } catch let error as LatencyBudget.Exceeded {
            XCTAssertEqual(error, LatencyBudget.Exceeded(milliseconds: 100))
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        XCTAssertLessThan(elapsed, 0.5, "budget returned after \(elapsed)s")
        try await Task.sleep(nanoseconds: 50_000_000) // real-time-ok: lets the cancelled task record its cancellation
        XCTAssertTrue(cancelled.isSet, "late operation was not cancelled")
    }

    // Turns red if the caller waits for an operation that ignores cancellation.
    func testCallerIsNotHeldByOperationIgnoringCancellation() async throws {
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await LatencyBudget.run(milliseconds: 50) { () async throws -> String in
                let deadline = ProcessInfo.processInfo.systemUptime + 0.4 // real-time-ok: busy loop that ignores cancellation
                while ProcessInfo.processInfo.systemUptime < deadline {
                    await Task.yield()
                }
                return "ignored"
            }
            XCTFail("expected budget to be exceeded")
        } catch is LatencyBudget.Exceeded {}
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.3)
    }

    // Turns red if an error from the operation is swallowed or replaced.
    func testOperationErrorPassesThrough() async {
        do {
            _ = try await LatencyBudget.run(milliseconds: 500) { () async throws -> String in throw Boom() }
            XCTFail("expected Boom")
        } catch is Boom {
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // Turns red if a zero budget stops meaning "no limit".
    func testZeroDisablesBudget() async throws {
        let unlimited = try await LatencyBudget.run(milliseconds: 0) {
            try await Task.sleep(nanoseconds: 20_000_000) // real-time-ok: short operation with no budget
            return 7
        }
        XCTAssertEqual(unlimited, 7)
    }

    // Turns red if cancelling the caller does not cancel the race.
    func testCancellingCallerCancelsRace() async throws {
        let outer = Task {
            try await LatencyBudget.run(milliseconds: 5000) { () async throws -> Int in
                try await Task.sleep(nanoseconds: 5_000_000_000) // real-time-ok: operation the caller cancels
                return 1
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000) // real-time-ok: lets the race start before cancelling
        outer.cancel()
        do {
            _ = try await outer.value
            XCTFail("expected cancellation")
        } catch is CancellationError {}
    }

    // Turns red if the settings clamp stops holding budgets inside the allowed range.
    func testClampKeepsBudgetInRange() {
        XCTAssertEqual(LatencyBudget.clamp(0), LatencyBudget.millisecondsRange.lowerBound)
        XCTAssertEqual(LatencyBudget.clamp(800), 800)
        XCTAssertEqual(LatencyBudget.clamp(60_000), LatencyBudget.millisecondsRange.upperBound)
    }
}
