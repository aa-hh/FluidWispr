import Combine
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class SpeechModelReadinessTests: XCTestCase {
    // Turns red if download progress stops reaching the published state or the caller's handler.
    func testDownloadProgressUpdatesActiveModelStateAndHandler() {
        let readiness = SpeechModelReadiness()
        var reported: [Double] = []

        readiness.applyModelPreparationProgress(
            .downloading(0.4),
            updatesActiveModelState: true,
            externalProgressHandler: { reported.append($0) }
        )

        XCTAssertTrue(readiness.isDownloadingModel)
        XCTAssertFalse(readiness.isLoadingModel)
        XCTAssertEqual(readiness.downloadProgress, 0.4)
        XCTAssertEqual(readiness.modelPreparationPhase, .downloading)
        XCTAssertEqual(reported, [0.4])
    }

    // Turns red if a download of a model that is not selected flips the active model's loading flags.
    func testBackgroundDownloadLeavesActiveModelFlagsAlone() {
        let readiness = SpeechModelReadiness()

        readiness.applyModelPreparationProgress(.loading, updatesActiveModelState: false, externalProgressHandler: nil)

        XCTAssertFalse(readiness.isLoadingModel)
        XCTAssertFalse(readiness.isDownloadingModel)
        XCTAssertNil(readiness.downloadProgress)
        XCTAssertEqual(readiness.modelPreparationPhase, .loading)
    }

    // Turns red if ASRService stops forwarding readiness changes, so views watching it would not refresh.
    func testASRServicePublishesReadinessChanges() {
        let asr = ASRService()
        var changes = 0
        let subscription = asr.objectWillChange.sink { _ in changes += 1 }

        asr.isAsrReady = true

        XCTAssertEqual(changes, 1)
        XCTAssertTrue(asr.isAsrReady)
        subscription.cancel()
    }
}
