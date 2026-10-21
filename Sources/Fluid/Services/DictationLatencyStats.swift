import Foundation

/// Rolling latency numbers for recent dictations, used to tune the cleanup
/// budgets. Kept in memory only; each dictation logs a DICTATION_LATENCY line
/// with the p50 and p95 so far.
nonisolated struct DictationLatencyStats {
    struct Sample: Equatable {
        let readyMilliseconds: Int
        let aiMilliseconds: Int?
        let cleanupTimedOut: Bool
    }

    struct Summary: Equatable {
        let count: Int
        let readyP50: Int
        let readyP95: Int
        let aiP50: Int?
        let aiP95: Int?
        let timeoutPercent: Int

        var logLine: String {
            "DICTATION_LATENCY n=\(self.count) readyP50Ms=\(self.readyP50) readyP95Ms=\(self.readyP95) "
                + "aiP50Ms=\(self.aiP50 ?? -1) aiP95Ms=\(self.aiP95 ?? -1) cleanupTimeouts=\(self.timeoutPercent)%"
        }
    }

    let capacity: Int
    private(set) var samples: [Sample] = []

    init(capacity: Int = 200) {
        self.capacity = max(1, capacity)
    }

    mutating func record(_ sample: Sample) {
        self.samples.append(sample)
        if self.samples.count > self.capacity {
            self.samples.removeFirst(self.samples.count - self.capacity)
        }
    }

    var summary: Summary? {
        guard !self.samples.isEmpty else { return nil }
        let ready = self.samples.map(\.readyMilliseconds).sorted()
        let ai = self.samples.compactMap(\.aiMilliseconds).sorted()
        let timeouts = self.samples.filter(\.cleanupTimedOut).count
        return Summary(
            count: self.samples.count,
            readyP50: Self.percentile(ready, 50),
            readyP95: Self.percentile(ready, 95),
            aiP50: ai.isEmpty ? nil : Self.percentile(ai, 50),
            aiP95: ai.isEmpty ? nil : Self.percentile(ai, 95),
            timeoutPercent: Int((Double(timeouts) * 100 / Double(self.samples.count)).rounded())
        )
    }

    /// Nearest-rank percentile of an already sorted, non-empty array.
    static func percentile(_ sorted: [Int], _ percent: Int) -> Int {
        let rank = Int((Double(percent) / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}

/// App-wide holder so recording a sample doesn't touch SwiftUI state.
final class DictationLatencyRecorder {
    static let shared = DictationLatencyRecorder()

    private var stats = DictationLatencyStats()

    /// Records one dictation and returns the updated summary.
    func record(_ sample: DictationLatencyStats.Sample) -> DictationLatencyStats.Summary? {
        self.stats.record(sample)
        return self.stats.summary
    }
}
