@testable import FluidVoice_Debug
import Foundation
import XCTest

final class UnfinishedDictationStoreTests: XCTestCase {
    private var directory: URL!
    private var store: UnfinishedDictationStore!

    override func setUpWithError() throws {
        // isolation-ok: a fresh folder per test, removed in tearDown.
        self.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FluidUnfinishedDictationTests-\(UUID().uuidString)", isDirectory: true)
        self.store = UnfinishedDictationStore(directory: self.directory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.directory)
    }

    private func samples(_ count: Int, seed: Float = 0.25) -> [Float] {
        (0 ..< count).map { Float($0 % 100) / 100 * seed }
    }

    // Turns red if kept audio stops reading back sample for sample, or recordings come back newest first.
    func testKeptAudioReadsBackOldestFirst() throws {
        let later = self.samples(16000, seed: 0.5)
        let earlier = self.samples(9000)
        try self.store.keep(later, recordedAt: Date(timeIntervalSince1970: 2000))
        try self.store.keep(earlier, recordedAt: Date(timeIntervalSince1970: 1000))

        let pending = self.store.pending()
        XCTAssertEqual(pending.map(\.recordedAt), [Date(timeIntervalSince1970: 1000), Date(timeIntervalSince1970: 2000)])
        XCTAssertEqual(try self.store.samples(of: pending[0]), earlier)
        XCTAssertEqual(try self.store.samples(of: pending[1]), later)

        self.store.remove(pending[0])
        XCTAssertEqual(self.store.pending().count, 1)
    }

    // Turns red if accidental taps get kept, or a recording that keeps failing is retried forever or deleted.
    func testShortTapsAreSkippedAndFailuresStopRetrying() throws {
        XCTAssertNil(try self.store.keep(self.samples(UnfinishedDictationStore.minimumSampleCount - 1)))
        XCTAssertTrue(self.store.pending().isEmpty)

        try self.store.keep(self.samples(16000), recordedAt: Date(timeIntervalSince1970: 3000))
        for attempt in 1 ... UnfinishedDictationStore.maxFailedAttempts {
            let item = try XCTUnwrap(self.store.pending().first)
            self.store.recordFailedAttempt(item)
            XCTAssertEqual(self.store.pending().count, attempt < UnfinishedDictationStore.maxFailedAttempts ? 1 : 0)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: self.directory.path)
        XCTAssertEqual(files, ["3000000-a3.f32"])
    }

    // Turns red if recovery input under one second stops being padded with trailing silence, or longer input gets changed.
    func testRecoveryInputIsPaddedToOneSecond() {
        let short = self.samples(9000)
        let padded = UnfinishedDictationStore.paddedForTranscription(short)
        XCTAssertEqual(padded.count, 16000)
        XCTAssertEqual(Array(padded.prefix(9000)), short)
        XCTAssertTrue(padded.dropFirst(9000).allSatisfy { $0 == 0 })
        let long = self.samples(20000)
        XCTAssertEqual(UnfinishedDictationStore.paddedForTranscription(long), long)
    }

    private struct TranscriptionFailed: Error {}

    private func keepThree() throws {
        for second in [1000.0, 2000.0, 3000.0] {
            try self.store.keep(self.samples(Int(second) * 8), recordedAt: Date(timeIntervalSince1970: second))
        }
    }

    // Turns red if one failing recording stops being charged and skipped, or a recording is deleted before save sees its text.
    @MainActor
    func testRecoveryMovesPastOneBadRecording() async throws {
        try self.keepThree()
        var saved: [Int] = []
        let count = await self.store.recoverPending(
            canContinue: { true },
            transcribe: { samples in
                if samples.count == 8000 { throw TranscriptionFailed() }
                return "words"
            },
            save: { _, text, sampleCount in
                XCTAssertEqual(text, "words")
                saved.append(sampleCount)
                return true
            }
        )
        XCTAssertEqual(count, 2)
        XCTAssertEqual(saved, [16000, 24000])
        XCTAssertEqual(self.store.pending().map(\.failedAttempts), [1])
    }

    // Turns red if a pass stops ending after two failures in a row, if a cancellation gets charged, or if canContinue is ignored.
    @MainActor
    func testRecoveryStopsOnRepeatedFailureCancellationOrBusy() async throws {
        try self.keepThree()
        _ = await self.store.recoverPending(canContinue: { true }, transcribe: { _ in throw TranscriptionFailed() }, save: { _, _, _ in true })
        XCTAssertEqual(self.store.pending().map(\.failedAttempts), [1, 1, 0])

        _ = await self.store.recoverPending(canContinue: { true }, transcribe: { _ in throw CancellationError() }, save: { _, _, _ in true })
        XCTAssertEqual(self.store.pending().map(\.failedAttempts), [1, 1, 0])

        let count = await self.store.recoverPending(canContinue: { false }, transcribe: { _ in "words" }, save: { _, _, _ in true })
        XCTAssertEqual(count, 0)
        XCTAssertEqual(self.store.pending().count, 3)
    }

    // Turns red if keeping a new recording stops pruning the oldest beyond the limit.
    func testOldestRecordingsArePrunedPastTheLimit() throws {
        let limit = UnfinishedDictationStore.maxKeptRecordings
        for second in 0 ... limit {
            try self.store.keep(self.samples(8000), recordedAt: Date(timeIntervalSince1970: Double(1000 + second)))
        }
        let pending = self.store.pending()
        XCTAssertEqual(pending.count, limit)
        XCTAssertEqual(pending.first?.recordedAt, Date(timeIntervalSince1970: 1001))
    }
}
