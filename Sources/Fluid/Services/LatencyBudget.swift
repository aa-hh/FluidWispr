import Foundation

/// Caps how long dictation waits for AI cleanup.
///
/// The operation races a timer. If the timer wins, the operation is cancelled
/// and `Exceeded` is thrown straight away, without waiting for the operation to
/// notice the cancellation, so the caller can paste the rule-cleaned text it
/// already has. A result that arrives after the budget is discarded.
nonisolated enum LatencyBudget {
    static let defaultMilliseconds = 800
    static let millisecondsRange: ClosedRange<Int> = 200...5000

    struct Exceeded: LocalizedError, Equatable {
        let milliseconds: Int

        var errorDescription: String? {
            "AI cleanup took longer than \(self.milliseconds) ms"
        }
    }

    static func clamp(_ milliseconds: Int) -> Int {
        min(max(milliseconds, self.millisecondsRange.lowerBound), self.millisecondsRange.upperBound)
    }

    /// Runs `operation` with a budget of `milliseconds`. A budget of 0 or less
    /// runs it without a limit.
    static func run<T: Sendable>(
        milliseconds: Int,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard milliseconds > 0 else { return try await operation() }
        try Task.checkCancellation()

        let race = Race<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                race.start(
                    work: Task {
                        do {
                            race.finish(.success(try await operation()))
                        } catch {
                            race.finish(.failure(error))
                        }
                    },
                    timer: Task {
                        do {
                            try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
                        } catch {
                            return
                        }
                        race.finish(.failure(Exceeded(milliseconds: milliseconds)))
                    }
                )
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

    /// Resumes the caller exactly once with whichever side finishes first,
    /// then cancels both tasks.
    private final class Race<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var outcome: Result<T, Error>?
        private var work: Task<Void, Never>?
        private var timer: Task<Void, Never>?

        func install(_ continuation: CheckedContinuation<T, Error>) {
            self.lock.lock()
            if let outcome = self.outcome {
                // Cancelled before the continuation existed.
                self.lock.unlock()
                continuation.resume(with: outcome)
                return
            }
            self.continuation = continuation
            self.lock.unlock()
        }

        func start(work: Task<Void, Never>, timer: Task<Void, Never>) {
            self.lock.lock()
            let alreadyFinished = self.outcome != nil
            if !alreadyFinished {
                self.work = work
                self.timer = timer
            }
            self.lock.unlock()

            if alreadyFinished {
                work.cancel()
                timer.cancel()
            }
        }

        func finish(_ result: Result<T, Error>) {
            self.lock.lock()
            guard self.outcome == nil else {
                self.lock.unlock()
                return
            }
            self.outcome = result
            let continuation = self.continuation
            self.continuation = nil
            let work = self.work
            let timer = self.timer
            self.work = nil
            self.timer = nil
            self.lock.unlock()

            work?.cancel()
            timer?.cancel()
            continuation?.resume(with: result)
        }
    }
}
