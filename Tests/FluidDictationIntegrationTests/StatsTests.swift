@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class StatsTests: XCTestCase {
    private var folders: [URL] = []
    private var suites: [String] = []

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        return calendar
    }

    override func tearDown() {
        for folder in self.folders {
            try? FileManager.default.removeItem(at: folder)
        }
        for suite in self.suites {
            UserDefaults().removePersistentDomain(forName: suite)
        }
        self.folders = []
        self.suites = []
        super.tearDown()
    }

    private func date(_ day: Int, month: Int = 9) -> Date {
        self.calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12)) ?? .distantPast
    }

    private func entry(_ day: Int, text: String, app: String = "Notes", ai: Bool = false, month: Int = 9) -> TranscriptionHistoryEntry {
        TranscriptionHistoryEntry(
            timestamp: self.date(day, month: month),
            rawText: "raw must not count",
            processedText: text,
            appName: app,
            windowTitle: "",
            wasAIProcessed: ai
        )
    }

    private var entries: [TranscriptionHistoryEntry] {
        [
            self.entry(7, text: "one  two\nthree", ai: true),
            self.entry(7, text: "four", app: ""),
            self.entry(6, text: "five six"),
            self.entry(4, text: "seven"),
            self.entry(3, text: "eight"),
        ]
    }

    // Turns red if the daily goal ladder changes, or a new day keeps yesterday's achievement.
    func testDailyMilestones() {
        let starting = StatsDailyMilestone(words: 0)
        XCTAssertEqual(starting.nextTarget, 100)
        XCTAssertNil(starting.reachedTarget, "A new day must not keep yesterday's achievement")
        XCTAssertEqual(starting.progress, 0)
        let approaching = StatsDailyMilestone(words: 288)
        XCTAssertEqual(approaching.nextTarget, 500)
        XCTAssertEqual(approaching.remaining, 212)
        XCTAssertEqual(approaching.reachedTarget, 250)
        let reached = StatsDailyMilestone(words: 500)
        XCTAssertEqual(reached.reachedTarget, 500)
        XCTAssertEqual(reached.nextTarget, 1000)
        XCTAssertEqual(reached.progress, 0.5)
        let completed = StatsDailyMilestone(words: 50_000)
        XCTAssertNil(completed.nextTarget)
        XCTAssertEqual(completed.remaining, 0)
        XCTAssertEqual(completed.progress, 1)
    }

    // Turns red if totals, streaks, records, top apps or hourly counts are miscounted, or building
    // the summary changes the history it reads.
    func testSnapshotTotalsStreaksAndRecords() throws {
        let entries = self.entries
        let original = entries
        let snapshot = try StatsSnapshot.build(entries: entries, now: self.date(7), calendar: self.calendar)
        XCTAssertEqual(entries, original, "The summary must not change history")
        XCTAssertEqual(snapshot.totalWords, 8)
        XCTAssertEqual(snapshot.totalTranscriptions, 5)
        XCTAssertEqual(snapshot.averageWordsPerTranscription, 1)
        XCTAssertEqual(snapshot.aiEnhancementRate, 20)
        XCTAssertEqual(snapshot.currentStreak, 2)
        XCTAssertEqual(snapshot.bestStreak, 2)
        XCTAssertEqual(snapshot.usingWeekdays(true).currentStreak, 3)
        XCTAssertEqual(snapshot.usingWeekdays(true).bestStreak, 3)
        XCTAssertEqual(snapshot.currentStreak, 2, "The settings view must not change the cached summary")
        XCTAssertEqual(snapshot.longestTranscriptionWords, 3)
        XCTAssertEqual(snapshot.mostWordsInDay, 4)
        XCTAssertEqual(snapshot.mostTranscriptionsInDay, 2)
        XCTAssertEqual(snapshot.dailyWordCounts(days: 7).count, 7)
        XCTAssertEqual(snapshot.activity.count, 180)
        XCTAssertEqual(snapshot.activity.last?.words, 4)
        XCTAssertEqual(snapshot.activity.reduce(0) { $0 + $1.words }, 8)
        XCTAssertEqual(snapshot.topAppsFormatted(limit: 3), ["Notes", "Unknown"])
        XCTAssertEqual(snapshot.topAppUsage.map(\.sessions), [4, 1])
        XCTAssertEqual(snapshot.hourlySessions.count, 24)
        XCTAssertEqual(snapshot.hourlySessions[12], 5)
        XCTAssertEqual(snapshot.hourlySessions.reduce(0, +), snapshot.totalTranscriptions)
        XCTAssertEqual(snapshot.formattedTimeSaved(typingWPM: 0), "< 1m")
        XCTAssertEqual(snapshot.formattedTimeSaved(typingWPM: 200), "< 1m")
        XCTAssertTrue(snapshot.dailyWordCounts(days: 0).isEmpty)
        XCTAssertEqual(snapshot.dailyWordCounts(days: 999).count, 180)

        let manyApps = try StatsSnapshot.build(
            entries: (0..<8).map { self.entry(7, text: "word", app: "App \($0)") },
            now: self.date(7),
            calendar: self.calendar
        )
        XCTAssertEqual(manyApps.topAppUsage.count, 5, "Top apps stay bounded")
        XCTAssertEqual(manyApps.totalTranscriptions, 8, "Percentages use all sessions")
        XCTAssertEqual(manyApps.topAppUsage.map(\.name), ["App 0", "App 1", "App 2", "App 3", "App 4"], "Ties stay in a fixed order")

        let empty = try StatsSnapshot.build(entries: [], now: self.date(7), calendar: self.calendar)
        XCTAssertEqual(empty.totalWords, 0)
        XCTAssertEqual(empty.currentStreak, 0)
        XCTAssertEqual(empty.bestStreak, 0)
        XCTAssertEqual(empty.peakHourFormatted, "N/A")
        XCTAssertTrue(empty.topAppUsage.isEmpty)
        XCTAssertEqual(empty.hourlySessions, Array(repeating: 0, count: 24))
        XCTAssertEqual(empty.totalMilestonesAchieved, 0)
        XCTAssertEqual(empty.totalMilestonesPossible, 18)
    }

    // Turns red if streaks break across weekends, DST or a gap in use, or the 180-day range cuts
    // into lifetime totals.
    func testStreakEdgesAndRangeLimits() throws {
        let entries = self.entries
        let oldHistory = try StatsSnapshot.build(entries: [self.entry(1, text: "old words", month: 1)] + entries, now: self.date(7), calendar: self.calendar)
        XCTAssertEqual(oldHistory.totalWords, 10)
        XCTAssertEqual(oldHistory.dailyWordCounts(days: 180).reduce(0) { $0 + $1.words }, 8, "The range limit must not change lifetime totals")
        let stale = try StatsSnapshot.build(entries: entries, now: self.date(10), calendar: self.calendar)
        XCTAssertEqual(stale.currentStreak, 0)
        XCTAssertEqual(stale.weekdayCurrentStreak, 0)
        XCTAssertEqual(stale.bestStreak, 2)
        let weekend = try StatsSnapshot.build(
            entries: [self.entry(3, text: "x"), self.entry(4, text: "x"), self.entry(6, text: "x")],
            now: self.date(6),
            calendar: self.calendar
        )
        XCTAssertEqual(weekend.weekdayCurrentStreak, 2)
        XCTAssertEqual(weekend.weekdayBestStreak, 2)
        let dst = try StatsSnapshot.build(
            entries: [self.entry(7, text: "a", month: 3), self.entry(8, text: "b", month: 3), self.entry(9, text: "c", month: 3)],
            now: self.date(9, month: 3),
            calendar: self.calendar
        )
        XCTAssertEqual(dst.currentStreak, 3, "Streaks must use calendar days across DST")
        XCTAssertEqual(dst.bestStreak, 3)
        let large = Array(repeating: self.entry(7, text: String(repeating: "word ", count: 100)), count: 9000)
        let big = try StatsSnapshot.build(entries: large, now: self.date(7), calendar: self.calendar)
        XCTAssertEqual(big.totalWords, 900_000)
        XCTAssertEqual(big.longestTranscriptionWords, 100)
        XCTAssertEqual(big.activity.count, 180)
    }

    // Turns red if the activity calendar pads, duplicates or misplaces days, or the weekday
    // averages ignore the first weekday setting.
    func testActivityPeriods() throws {
        let calendar = self.calendar
        let snapshot = try StatsSnapshot.build(entries: self.entries, now: self.date(7), calendar: calendar)
        for count in [30, 60, 90, 180] {
            let period = StatsActivityPeriod(activity: snapshot.dailyWordCounts(days: count), calendar: calendar)
            XCTAssertEqual(period.days.count, count)
            XCTAssertEqual(period.totalWords, 8)
            XCTAssertEqual(period.activeDays, 4)
            XCTAssertEqual(period.days.last?.cumulativeWords, 8)
            XCTAssertEqual(period.weeks.flatMap { $0 }.compactMap { $0 }.count, count, "Padding must not duplicate days")
            for week in period.weeks {
                XCTAssertEqual(week.count, 7)
                for (row, day) in week.enumerated() {
                    if let day {
                        XCTAssertEqual((calendar.component(.weekday, from: day.date) - calendar.firstWeekday + 7) % 7, row)
                    }
                }
            }
        }
        let empty = try StatsSnapshot.build(entries: [], now: self.date(7), calendar: calendar)
        let emptyPeriod = StatsActivityPeriod(activity: empty.activity, calendar: calendar)
        XCTAssertEqual(emptyPeriod.totalWords, 0)
        XCTAssertNil(emptyPeriod.strongestWeekday)
        let shortPeriod = StatsActivityPeriod(activity: snapshot.dailyWordCounts(days: 7), calendar: calendar)
        XCTAssertEqual(shortPeriod.weekdays.first { $0.id == 1 }?.averageWords, 4, "The Monday average uses every Monday in range")
        var mondayCalendar = calendar
        mondayCalendar.firstWeekday = 2
        let mondayPeriod = StatsActivityPeriod(activity: snapshot.activity, calendar: mondayCalendar)
        XCTAssertEqual(mondayPeriod.weekdays.first?.id, 1)
    }

    // Turns red if a cancelled summary build still returns a result.
    func testCancelledBuildThrows() async throws {
        let large = Array(repeating: self.entry(7, text: String(repeating: "word ", count: 100)), count: 9000)
        let cancelled = Task.detached {
            try await Task.sleep(nanoseconds: 50_000_000) // real-time-ok: cancellation lands before the build starts
            return try StatsSnapshot.build(entries: large, now: Date(), calendar: Calendar.current)
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("A cancelled worker must not return a snapshot")
        } catch is CancellationError {}
    }

    // Turns red if hidden Stats aggregates history, reopening redoes unchanged work, an older
    // history value wins over a newer one, closing one window cancels another, or Stats writes
    // to history.
    func testStoreOnlyWorksWhileVisible() async throws {
        let root = FileManager.default.temporaryDirectory // isolation-ok: unique folder removed in tearDown
            .appendingPathComponent("StatsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.folders.append(root)
        let suite = "StatsTests.\(UUID().uuidString)"
        self.suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)) // isolation-ok: throwaway suite
        let history = TranscriptionHistoryStore(
            writer: TranscriptionHistoryWriter(defaults: defaults, url: root.appendingPathComponent("history.sqlite3")),
            audioStore: DictationAudioHistoryStore(directory: root.appendingPathComponent("audio", isDirectory: true))
        )
        try await history.waitUntilLoaded()
        let entries = self.entries
        let store = StatsSnapshotStore(history: history)
        let first = UUID()
        let second = UUID()

        func settle() async throws {
            for _ in 0..<100 where store.isUpdating {
                try await Task.sleep(nanoseconds: 10_000_000) // real-time-ok: the store builds on a background task
            }
        }

        history.restore(from: entries)
        try await Task.sleep(nanoseconds: 100_000_000) // real-time-ok: gives a hidden store time to start work it must not do
        XCTAssertNil(store.snapshot, "Hidden Stats must not aggregate")
        XCTAssertFalse(store.isUpdating)
        store.activate(first)
        try await settle()
        XCTAssertEqual(store.snapshot?.totalWords, 8)
        XCTAssertFalse(store.isUpdating)
        store.deactivate(first)
        store.activate(first)
        XCTAssertFalse(store.isUpdating, "Reopening unchanged Stats must use the cache")
        history.restore(from: Array(repeating: entries[0], count: 1000))
        history.restore(from: [entries[1]])
        try await settle()
        XCTAssertEqual(store.snapshot?.totalWords, 1, "Only the newest history value may win")
        store.activate(second)
        store.deactivate(first)
        history.restore(from: entries)
        try await settle()
        XCTAssertEqual(store.snapshot?.totalWords, 8, "One window closing must not cancel another")
        history.restore(from: Array(repeating: entries[0], count: 1000))
        store.deactivate(second)
        try await Task.sleep(nanoseconds: 100_000_000) // real-time-ok: gives cancelled work time to publish if it wrongly could
        XCTAssertFalse(store.isUpdating)
        XCTAssertEqual(store.snapshot?.totalWords, 8, "Hidden cancelled work cannot publish")
        history.restore(from: [])
        XCTAssertNil(store.snapshot, "A reset must drop old totals at once")
        store.activate(first)
        try await settle()
        XCTAssertEqual(store.snapshot?.totalWords, 0)
        XCTAssertEqual(store.snapshot?.totalTranscriptions, 0)
        XCTAssertTrue(history.entries.isEmpty, "Stats must never write to history")
        store.deactivate(first)
        await history.finishPendingWrites()
    }
}
