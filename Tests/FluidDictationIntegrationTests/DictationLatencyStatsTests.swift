@testable import FluidVoice_Debug
import XCTest

final class DictationLatencyStatsTests: XCTestCase {
    // Turns red if the percentile or timeout summary is computed from the wrong samples.
    func testSummaryPercentilesAndTimeoutShare() throws {
        var stats = DictationLatencyStats(capacity: 5)
        XCTAssertNil(stats.summary)

        for ready in [100, 200, 300, 400, 500] {
            stats.record(.init(readyMilliseconds: ready, aiMilliseconds: ready / 2, cleanupTimedOut: ready == 500))
        }
        let summary = try XCTUnwrap(stats.summary)
        XCTAssertEqual(summary.count, 5)
        XCTAssertEqual(summary.readyP50, 300)
        XCTAssertEqual(summary.readyP95, 500)
        XCTAssertEqual(summary.aiP50, 150)
        XCTAssertEqual(summary.timeoutPercent, 20)

        // Oldest samples drop out once capacity is reached.
        stats.record(.init(readyMilliseconds: 900, aiMilliseconds: nil, cleanupTimedOut: false))
        XCTAssertEqual(stats.samples.count, 5)
        XCTAssertEqual(stats.samples.first?.readyMilliseconds, 200)
        XCTAssertEqual(stats.summary?.readyP95, 900)
    }

    // Turns red if dictations without AI cleanup report a made-up AI latency.
    func testDictationsWithoutCleanupLeaveAIPercentilesEmpty() throws {
        var noAI = DictationLatencyStats()
        noAI.record(.init(readyMilliseconds: 250, aiMilliseconds: nil, cleanupTimedOut: false))
        let summary = try XCTUnwrap(noAI.summary)
        XCTAssertNil(summary.aiP50)
        XCTAssertTrue(summary.logLine.contains("aiP50Ms=-1"))
    }

    // Turns red if the nearest-rank percentile rounds the wrong way.
    func testPercentileUsesNearestRank() {
        XCTAssertEqual(DictationLatencyStats.percentile([7], 95), 7)
        XCTAssertEqual(DictationLatencyStats.percentile([1, 2, 3, 4], 50), 2)
    }
}
