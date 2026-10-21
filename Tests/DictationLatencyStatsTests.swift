import Foundation

@main
enum DictationLatencyStatsTests {
    static func main() {
        var stats = DictationLatencyStats(capacity: 5)
        precondition(stats.summary == nil)

        for ready in [100, 200, 300, 400, 500] {
            stats.record(.init(readyMilliseconds: ready, aiMilliseconds: ready / 2, cleanupTimedOut: ready == 500))
        }
        let summary = stats.summary!
        precondition(summary.count == 5)
        precondition(summary.readyP50 == 300)
        precondition(summary.readyP95 == 500)
        precondition(summary.aiP50 == 150)
        precondition(summary.timeoutPercent == 20)

        // Oldest samples drop out once capacity is reached.
        stats.record(.init(readyMilliseconds: 900, aiMilliseconds: nil, cleanupTimedOut: false))
        precondition(stats.samples.count == 5)
        precondition(stats.samples.first?.readyMilliseconds == 200)
        precondition(stats.summary!.readyP95 == 900)

        // Dictations without AI cleanup leave the AI percentiles empty.
        var noAI = DictationLatencyStats()
        noAI.record(.init(readyMilliseconds: 250, aiMilliseconds: nil, cleanupTimedOut: false))
        precondition(noAI.summary!.aiP50 == nil)
        precondition(noAI.summary!.logLine.contains("aiP50Ms=-1"))

        precondition(DictationLatencyStats.percentile([7], 95) == 7)
        precondition(DictationLatencyStats.percentile([1, 2, 3, 4], 50) == 2)

        print("DictationLatencyStatsTests passed")
    }
}
