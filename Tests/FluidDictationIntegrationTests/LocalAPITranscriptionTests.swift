import AVFoundation
@testable import FluidVoice_Debug
import Foundation
import XCTest

/// A ready provider that records what the local API sends it. `holdFinal` parks the
/// model call so a test can look at who owns the speech engine while it runs.
@MainActor
private final class LocalAPIFixtureProvider: TranscriptionProvider {
    let name = "Local API fixture"
    let isAvailable = true
    var isReady = true
    var prefersNativeFileTranscription = false
    var failTranscription = false
    var holdFinal = false
    var finalCalls: [[Float]] = []
    var fileCalls = 0
    var heldFinal: CheckedContinuation<Void, Never>?

    func prepare(progressHandler _: ((ModelPreparationProgress) -> Void)?) async throws {}

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribeFinal(samples)
    }

    func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        self.finalCalls.append(samples)
        if self.holdFinal { await withCheckedContinuation { self.heldFinal = $0 } }
        if self.failTranscription { throw CancellationError() }
        return ASRTranscriptionResult(text: "sample result", confidence: 0.8)
    }

    func transcribeFile(at _: URL) async throws -> ASRTranscriptionResult {
        self.fileCalls += 1
        if self.failTranscription { throw CancellationError() }
        return ASRTranscriptionResult(text: "file result", confidence: 0.8)
    }
}

@MainActor
final class LocalAPITranscriptionTests: XCTestCase {
    private var files: [URL] = []

    override func tearDown() async throws {
        for file in self.files {
            try? FileManager.default.removeItem(at: file)
        }
        self.files = []
        try await super.tearDown()
    }

    private func makeService() -> (ASRService, LocalAPIFixtureProvider) {
        let service = ASRService()
        let provider = LocalAPIFixtureProvider()
        service.modelProvidersForTesting[SettingsStore.shared.selectedSpeechModel] = provider
        service.isAsrReady = true
        return (service, provider)
    }

    /// A 16 kHz mono float WAV holding `count` samples of 0.1.
    private func makeAudioFile(sampleCount count: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory // isolation-ok: unique name, removed in tearDown
            .appendingPathComponent("LocalAPITranscriptionTests-\(UUID().uuidString).wav")
        self.files.append(url)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        if count > 0 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            buffer.frameLength = AVAudioFrameCount(count)
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            for index in 0..<count {
                channel[index] = 0.1
            }
            try file.write(from: buffer)
        }
        return url
    }

    private func waitUntil(_ reached: () -> Bool) async {
        for _ in 0..<100_000 where !reached() {
            await Task.yield()
        }
        XCTAssertTrue(reached(), "The request never reached the provider")
    }

    // Turns red if uploads stop going to the provider's own file path at one second or more, short or
    // non-native uploads stop reaching the model at one second or longer, or the response stops reporting
    // the upload's real length. The decoder may split or resample audio, so exact padding is checked on raw samples below.
    func testUploadsAreRoutedByLengthAndReleaseTheEngine() async throws {
        for native in [false, true] {
            for count in [1, 15_999, 16_000, 32_000] {
                let (service, provider) = self.makeService()
                provider.prefersNativeFileTranscription = native
                let (result, reportedCount) = try await service.transcribeFileForAPI(self.makeAudioFile(sampleCount: count))
                let label = "native: \(native), samples: \(count)"

                XCTAssertEqual(reportedCount, count, label)
                let sentWhole = native && count >= 16_000
                XCTAssertEqual(provider.fileCalls, sentWhole ? 1 : 0, label)
                if sentWhole {
                    XCTAssertTrue(provider.finalCalls.isEmpty, label)
                } else {
                    XCTAssertFalse(provider.finalCalls.isEmpty, label)
                    XCTAssertTrue(provider.finalCalls.allSatisfy { $0.count >= 16_000 }, label)
                    XCTAssertTrue(result.text.lowercased().contains("sample result"), label)
                }
                XCTAssertNil(service.activeExclusiveActivity, label)
            }
        }
    }

    // Turns red if a missing file, an unreadable file, or a failed model call leaves the local API holding the speech engine.
    func testFailuresReleaseTheEngine() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("LocalAPITranscriptionTests-missing-\(UUID().uuidString).wav") // isolation-ok: never created
        let garbage = FileManager.default.temporaryDirectory.appendingPathComponent("LocalAPITranscriptionTests-\(UUID().uuidString).wav") // isolation-ok: removed in tearDown
        self.files.append(garbage)
        try Data("not audio".utf8).write(to: garbage)
        let shortAudio = try self.makeAudioFile(sampleCount: 8000)

        for (label, url, failsInModel) in [("missing", missing, false), ("unreadable", garbage, false), ("model error", shortAudio, true)] {
            let (service, provider) = self.makeService()
            provider.failTranscription = failsInModel
            do {
                _ = try await service.transcribeFileForAPI(url)
                XCTFail("\(label) should fail")
            } catch {}
            XCTAssertNil(service.activeExclusiveActivity, label)
        }
    }

    // Turns red if a local API request can start while dictation owns the engine, or releases dictation's lease when refused.
    func testBusyEngineRejectsTheRequestAndKeepsTheOtherLease() async throws {
        let (service, provider) = self.makeService()
        let dictation = try service.acquireExclusiveActivity(.dictation)
        do {
            _ = try await service.transcribeFileForAPI(self.makeAudioFile(sampleCount: 8000))
            XCTFail("The request should be refused while dictation runs")
        } catch let ASRActivityError.activityInProgress(activity) {
            XCTAssertEqual(activity, .dictation)
        }
        XCTAssertEqual(service.activeExclusiveActivity, .dictation)
        XCTAssertTrue(provider.finalCalls.isEmpty)
        XCTAssertEqual(provider.fileCalls, 0)
        service.releaseExclusiveActivity(dictation)
    }

    // Turns red if the local API lets go of the engine while the model is still working, so dictation could start on top of it.
    func testEngineStaysOwnedWhileTheModelWorks() async throws {
        let (service, provider) = self.makeService()
        provider.holdFinal = true
        let audio = try self.makeAudioFile(sampleCount: 8000)
        let request = Task { try await service.transcribeFileForAPI(audio) }
        await self.waitUntil { provider.heldFinal != nil }

        XCTAssertEqual(service.activeExclusiveActivity, .localAPI)
        XCTAssertThrowsError(try service.acquireExclusiveActivity(.dictation))
        provider.heldFinal?.resume()
        _ = try await request.value

        XCTAssertNil(service.activeExclusiveActivity)
        let dictation = try service.acquireExclusiveActivity(.dictation)
        service.releaseExclusiveActivity(dictation)
    }

    // Turns red if raw samples sent to the local API skip the lease, lose their values, or stop being padded to one second with silence.
    func testRawSamplesArePaddedAndReleaseTheEngine() async throws {
        for count in [1, 15_999, 16_000, 32_000] {
            let (service, provider) = self.makeService()
            _ = try await service.transcribeSamplesForAPI(Array(repeating: 0.1, count: count))
            let samples = provider.finalCalls.first ?? []
            XCTAssertEqual(provider.finalCalls.count, 1, "samples: \(count)")
            XCTAssertEqual(samples.count, max(16_000, count), "samples: \(count)")
            XCTAssertTrue(samples.prefix(count).allSatisfy { $0 == 0.1 }, "samples: \(count)")
            XCTAssertTrue(samples.dropFirst(count).allSatisfy { $0 == 0 }, "samples: \(count)")
            XCTAssertNil(service.activeExclusiveActivity, "samples: \(count)")
        }
    }
}
