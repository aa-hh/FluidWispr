@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
private final class OnboardingAISetupHarness {
    typealias Controller = OnboardingAISetupController
    var installed = false
    var failRecommendation = false
    var failDownload = false
    var failLoad = false
    var pauseDownload = false
    var pauseLoad = false
    var readCount = 0
    var downloads = 0
    var loads = 0
    var commits = 0
    var downloadContinuation: CheckedContinuation<Void, Never>?
    var loadContinuation: CheckedContinuation<Void, Never>?
    var progressCallback: (@Sendable (Controller.Progress) async -> Void)?
    var lastID: String?
    var pendingDownload = false
    enum Failure: Error { case simulated }

    func controller() -> Controller {
        Controller(dependencies: .init(
            recommend: {
                self.readCount += 1
                if self.failRecommendation { throw Failure.simulated }
                return .init(id: "pico", name: "Pico", byteCount: 100, installed: self.installed)
            },
            prepare: { model, progress in
                self.downloads += 1
                self.lastID = model.id
                self.progressCallback = progress
                await progress(.init(fraction: 0.5, status: "Downloading", bytes: "50 of 100"))
                if self.pauseDownload {
                    await withCheckedContinuation { self.downloadContinuation = $0 }
                }
                if self.failDownload { throw Failure.simulated }
            },
            load: { model in
                self.loads += 1
                self.lastID = model.id
                if self.pauseLoad {
                    await withCheckedContinuation { self.loadContinuation = $0 }
                }
                if self.failLoad { throw Failure.simulated }
            },
            readPendingDownload: { self.pendingDownload },
            writePendingDownload: { self.pendingDownload = $0 }
        ))
    }
}

@MainActor
final class OnboardingAISetupControllerTests: XCTestCase {
    private struct TimedOut: Error {}

    // Spins on Task.yield, not the clock, until the controller reaches the expected state.
    // Throws on timeout so the test stops at the first state it never reached.
    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<10_000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for controller", file: file, line: line)
        throw TimedOut()
    }

    // Turns red if a relaunch resumes a saved download request by activating the model, or
    // if a cancelled or already installed request downloads again.
    func testPersistedDownloadRequestIsRecoveredButNeverActivated() async throws {
        // A newly created controller recovers a persisted request, never activation.
        let restarted = OnboardingAISetupHarness()
        restarted.pendingDownload = true
        restarted.failDownload = true
        let firstProcess = restarted.controller()
        firstProcess.resumePendingDownload()
        try await self.waitUntil { firstProcess.errorMessage != nil }
        XCTAssertTrue(restarted.pendingDownload)
        XCTAssertEqual(restarted.loads, 0)
        XCTAssertEqual(restarted.commits, 0)
        restarted.failDownload = false
        let nextProcess = restarted.controller()
        nextProcess.resumePendingDownload()
        try await self.waitUntil { !restarted.pendingDownload }
        XCTAssertEqual(restarted.downloads, 2)
        XCTAssertEqual(restarted.loads, 0)
        XCTAssertEqual(restarted.commits, 0)
        firstProcess.cancel()

        let cancelled = OnboardingAISetupHarness()
        cancelled.pendingDownload = true
        cancelled.controller().cancel()
        cancelled.controller().resumePendingDownload()
        XCTAssertFalse(cancelled.pendingDownload)
        XCTAssertEqual(cancelled.downloads, 0)

        let saved = OnboardingAISetupHarness()
        saved.installed = true
        saved.pendingDownload = true
        let savedController = saved.controller()
        savedController.resumePendingDownload()
        try await self.waitUntil { !saved.pendingDownload }
        XCTAssertEqual(saved.downloads, 0)
        XCTAssertEqual(saved.loads, 0)
        XCTAssertEqual(saved.commits, 0)
    }

    // Turns red if a double click activates twice, late progress from a finished download
    // reappears, or returning to the page reloads the model.
    func testActivationRunsOnceAndIgnoresStaleProgress() async throws {
        let fresh = OnboardingAISetupHarness()
        let controller = fresh.controller()
        controller.refresh()
        controller.refresh()
        try await self.waitUntil { controller.phase == .offered }
        XCTAssertEqual(fresh.readCount, 1)
        XCTAssertEqual(fresh.downloads, 0)
        XCTAssertEqual(fresh.loads, 0)
        XCTAssertEqual(fresh.commits, 0)
        controller.enable { _ in fresh.commits += 1 }
        controller.enable { _ in XCTFail("Duplicate action") }
        try await self.waitUntil { controller.phase == .ready }
        XCTAssertEqual(fresh.downloads, 1)
        XCTAssertEqual(fresh.loads, 1)
        XCTAssertEqual(fresh.commits, 1)
        XCTAssertEqual(fresh.lastID, "pico")
        await fresh.progressCallback?(.init(fraction: 0.1, status: "stale", bytes: nil))
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertNil(controller.progress)
        controller.introductionFinished = true
        controller.cancel() // Leaving the AI page after setup has finished.
        controller.refresh() // Returning to that page reuses the flow-owned controller.
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertTrue(controller.introductionFinished)
        XCTAssertEqual(fresh.readCount, 1)
        XCTAssertEqual(fresh.loads, 1)
        XCTAssertEqual(fresh.commits, 1)
        controller.introductionFinished = false // Explicit Replay changes only video progress.
        XCTAssertEqual(controller.phase, .ready)
        XCTAssertEqual(fresh.loads, 1)
        XCTAssertEqual(fresh.commits, 1)
    }

    // Turns red if prefetch downloads twice, activates without the user, or leaves a
    // cancelled prefetch unable to retry.
    func testPrefetchDownloadsOnceAndCancelsCleanly() async throws {
        let prefetched = OnboardingAISetupHarness()
        prefetched.pauseDownload = true
        let prefetchedController = prefetched.controller()
        prefetchedController.prefetch()
        prefetchedController.prefetch()
        try await self.waitUntil { prefetched.downloadContinuation != nil }
        XCTAssertEqual(prefetchedController.phase, .downloading)
        XCTAssertTrue(prefetchedController.canEnable)
        XCTAssertFalse(prefetchedController.showsPreparationProgress)
        XCTAssertEqual(prefetched.readCount, 1)
        XCTAssertEqual(prefetched.downloads, 1)
        XCTAssertEqual(prefetched.loads, 0)
        XCTAssertEqual(prefetched.commits, 0)
        prefetchedController.enable { _ in prefetched.commits += 1 }
        XCTAssertFalse(prefetchedController.canEnable)
        XCTAssertTrue(prefetchedController.showsPreparationProgress)
        prefetchedController.enable { _ in XCTFail("Duplicate activation") }
        prefetched.downloadContinuation?.resume()
        try await self.waitUntil { prefetchedController.phase == .ready }
        XCTAssertEqual(prefetched.downloads, 1)
        XCTAssertEqual(prefetched.loads, 1)
        XCTAssertEqual(prefetched.commits, 1)

        let prefetchedCached = OnboardingAISetupHarness()
        prefetchedCached.installed = true
        let prefetchedCachedController = prefetchedCached.controller()
        prefetchedCachedController.prefetch()
        try await self.waitUntil { prefetchedCachedController.phase == .offered }
        XCTAssertEqual(prefetchedCached.readCount, 1)
        XCTAssertEqual(prefetchedCached.downloads, 0)
        XCTAssertEqual(prefetchedCached.loads, 0)

        let cancelledPrefetch = OnboardingAISetupHarness()
        cancelledPrefetch.pauseDownload = true
        let cancelledPrefetchController = cancelledPrefetch.controller()
        cancelledPrefetchController.prefetch()
        try await self.waitUntil { cancelledPrefetch.downloadContinuation != nil }
        cancelledPrefetchController.enable { _ in XCTFail("Cancelled activation") }
        cancelledPrefetchController.cancel()
        XCTAssertEqual(cancelledPrefetchController.phase, .cancelling)
        XCTAssertNil(cancelledPrefetchController.progress)
        cancelledPrefetch.downloadContinuation?.resume()
        try await self.waitUntil { cancelledPrefetchController.phase == .offered }
        cancelledPrefetch.pauseDownload = false
        cancelledPrefetchController.enable { _ in cancelledPrefetch.commits += 1 }
        try await self.waitUntil { cancelledPrefetchController.phase == .ready }
        XCTAssertEqual(cancelledPrefetch.downloads, 2)
        XCTAssertEqual(cancelledPrefetch.loads, 1)
        XCTAssertEqual(cancelledPrefetch.commits, 1)
    }

    // Turns red if leaving onboarding cancels a "set up later" download, or an installed
    // model is downloaded again on activation.
    func testSetUpLaterOutlivesOnboardingAndCachedModelSkipsDownload() async throws {
        let cached = OnboardingAISetupHarness()
        let deferred = OnboardingAISetupHarness()
        deferred.pauseDownload = true
        var deferredController: OnboardingAISetupController? = deferred.controller()
        weak var retainedDownload = deferredController
        deferredController?.setUpLater()
        try await self.waitUntil { deferred.downloadContinuation != nil }
        deferredController?.leavePage()
        deferredController = nil
        XCTAssertNotNil(retainedDownload, "Download survives onboarding dismissal")
        deferred.downloadContinuation?.resume()
        deferred.progressCallback = nil
        try await self.waitUntil { retainedDownload == nil }
        XCTAssertEqual(deferred.downloads, 1)
        XCTAssertEqual(deferred.loads, 0)
        XCTAssertEqual(deferred.commits, 0)

        cached.installed = true
        let cachedController = cached.controller()
        cachedController.refresh()
        try await self.waitUntil { cachedController.phase == .offered }
        cachedController.enable { _ in cached.commits += 1 }
        try await self.waitUntil { cachedController.phase == .ready }
        XCTAssertEqual(cached.downloads, 0)
        XCTAssertEqual(cached.loads, 1)
        XCTAssertEqual(cached.commits, 1)
    }

    // Turns red if cancelling mid-download or mid-load still commits, lets new work overlap
    // the cancelled work, or shows progress from the old operation.
    func testCancellationDuringDownloadOrLoad() async throws {
        for cancelDuringLoad in [false, true] {
            let harness = OnboardingAISetupHarness()
            harness.pauseDownload = !cancelDuringLoad
            harness.pauseLoad = cancelDuringLoad
            let operation = harness.controller()
            operation.refresh()
            try await self.waitUntil { operation.phase == .offered }
            operation.enable { _ in harness.commits += 1 }
            try await self.waitUntil { cancelDuringLoad ? harness.loadContinuation != nil : harness.downloadContinuation != nil }
            operation.cancel()
            operation.cancel()
            XCTAssertEqual(operation.phase, .cancelling)
            XCTAssertNil(operation.progress)
            operation.enable { _ in XCTFail("Cannot overlap cancelled work") }
            await harness.progressCallback?(.init(fraction: 0.9, status: "late", bytes: nil))
            XCTAssertNil(operation.progress)
            harness.downloadContinuation?.resume()
            harness.loadContinuation?.resume()
            try await self.waitUntil { operation.phase == .offered }
            XCTAssertEqual(harness.commits, 0)
            XCTAssertNil(operation.errorMessage)
            XCTAssertEqual(harness.loads, cancelDuringLoad ? 1 : 0)
            let oldProgress = harness.progressCallback
            harness.pauseDownload = false
            harness.pauseLoad = false
            operation.enable { _ in harness.commits += 1 }
            try await self.waitUntil { operation.phase == .ready }
            await oldProgress?(.init(fraction: 0.2, status: "old operation", bytes: nil))
            XCTAssertNil(operation.progress)
            XCTAssertEqual(harness.commits, 1)
        }
    }

    // Turns red if a failed download, load or recommendation strands the controller, or a
    // rejected commit is treated as success.
    func testFailuresLeaveOfferAndRetrySucceeds() async throws {
        for downloadFailure in [true, false] {
            let harness = OnboardingAISetupHarness()
            harness.failDownload = downloadFailure
            harness.failLoad = !downloadFailure
            let operation = harness.controller()
            operation.refresh()
            try await self.waitUntil { operation.phase == .offered }
            operation.enable { _ in harness.commits += 1 }
            try await self.waitUntil { operation.errorMessage != nil }
            XCTAssertEqual(operation.phase, .offered)
            XCTAssertEqual(harness.commits, 0)
            XCTAssertNil(operation.progress)
            harness.failDownload = false
            harness.failLoad = false
            operation.enable { _ in harness.commits += 1 }
            try await self.waitUntil { operation.phase == .ready }
            XCTAssertEqual(harness.commits, 1)
        }

        let unavailable = OnboardingAISetupHarness()
        unavailable.failRecommendation = true
        let missing = unavailable.controller()
        missing.refresh()
        try await self.waitUntil { missing.phase == .unavailable }
        XCTAssertEqual(unavailable.downloads, 0)
        XCTAssertEqual(unavailable.commits, 0)
        unavailable.failRecommendation = false
        missing.refresh()
        try await self.waitUntil { missing.phase == .offered }
        missing.enable { _ in throw OnboardingAISetupHarness.Failure.simulated }
        try await self.waitUntil { missing.errorMessage != nil }
        XCTAssertEqual(missing.phase, .offered)
        XCTAssertEqual(unavailable.commits, 0)
    }
}
