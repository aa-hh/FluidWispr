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
    // Spins on Task.yield, not the clock, until the controller reaches the expected state.
    private func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<10_000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for controller", file: file, line: line)
    }

    // Turns red if a relaunch resumes a saved download request by activating the model, or
    // if a cancelled or already installed request downloads again.
    func testPersistedDownloadRequestIsRecoveredButNeverActivated() async {
        // A newly created controller recovers a persisted request, never activation.
        let restarted = OnboardingAISetupHarness()
        restarted.pendingDownload = true
        restarted.failDownload = true
        let firstProcess = restarted.controller()
        firstProcess.resumePendingDownload()
        await self.waitUntil { firstProcess.errorMessage != nil }
        XCTAssertTrue(restarted.pendingDownload && restarted.loads == 0 && restarted.commits == 0)
        restarted.failDownload = false
        let nextProcess = restarted.controller()
        nextProcess.resumePendingDownload()
        await self.waitUntil { !restarted.pendingDownload }
        XCTAssertTrue(restarted.downloads == 2 && restarted.loads == 0 && restarted.commits == 0)
        firstProcess.cancel()

        let cancelled = OnboardingAISetupHarness()
        cancelled.pendingDownload = true
        cancelled.controller().cancel()
        cancelled.controller().resumePendingDownload()
        XCTAssertTrue(!cancelled.pendingDownload && cancelled.downloads == 0)

        let saved = OnboardingAISetupHarness()
        saved.installed = true
        saved.pendingDownload = true
        let savedController = saved.controller()
        savedController.resumePendingDownload()
        await self.waitUntil { !saved.pendingDownload }
        XCTAssertTrue(saved.downloads == 0 && saved.loads == 0 && saved.commits == 0)
    }

    // Turns red if a double click activates twice, late progress from a finished download
    // reappears, or returning to the page reloads the model.
    func testActivationRunsOnceAndIgnoresStaleProgress() async {
        let fresh = OnboardingAISetupHarness()
        let controller = fresh.controller()
        controller.refresh()
        controller.refresh()
        await self.waitUntil { controller.phase == .offered }
        XCTAssertTrue(fresh.readCount == 1 && fresh.downloads == 0 && fresh.loads == 0 && fresh.commits == 0)
        controller.enable { _ in fresh.commits += 1 }
        controller.enable { _ in XCTFail("Duplicate action") }
        await self.waitUntil { controller.phase == .ready }
        XCTAssertTrue(fresh.downloads == 1 && fresh.loads == 1 && fresh.commits == 1 && fresh.lastID == "pico")
        await fresh.progressCallback?(.init(fraction: 0.1, status: "stale", bytes: nil))
        XCTAssertTrue(controller.phase == .ready && controller.progress == nil)
        controller.introductionFinished = true
        controller.cancel() // Leaving the AI page after setup has finished.
        controller.refresh() // Returning to that page reuses the flow-owned controller.
        XCTAssertTrue(controller.phase == .ready && controller.introductionFinished)
        XCTAssertTrue(fresh.readCount == 1 && fresh.loads == 1 && fresh.commits == 1)
        controller.introductionFinished = false // Explicit Replay changes only video progress.
        XCTAssertTrue(controller.phase == .ready && fresh.loads == 1 && fresh.commits == 1)
    }

    // Turns red if prefetch downloads twice, activates without the user, or leaves a
    // cancelled prefetch unable to retry.
    func testPrefetchDownloadsOnceAndCancelsCleanly() async {
        let prefetched = OnboardingAISetupHarness()
        prefetched.pauseDownload = true
        let prefetchedController = prefetched.controller()
        prefetchedController.prefetch()
        prefetchedController.prefetch()
        await self.waitUntil { prefetched.downloadContinuation != nil }
        XCTAssertTrue(prefetchedController.phase == .downloading)
        XCTAssertTrue(prefetchedController.canEnable && !prefetchedController.showsPreparationProgress)
        XCTAssertTrue(prefetched.readCount == 1 && prefetched.downloads == 1 && prefetched.loads == 0 && prefetched.commits == 0)
        prefetchedController.enable { _ in prefetched.commits += 1 }
        XCTAssertTrue(!prefetchedController.canEnable && prefetchedController.showsPreparationProgress)
        prefetchedController.enable { _ in XCTFail("Duplicate activation") }
        prefetched.downloadContinuation?.resume()
        await self.waitUntil { prefetchedController.phase == .ready }
        XCTAssertTrue(prefetched.downloads == 1 && prefetched.loads == 1 && prefetched.commits == 1)

        let prefetchedCached = OnboardingAISetupHarness()
        prefetchedCached.installed = true
        let prefetchedCachedController = prefetchedCached.controller()
        prefetchedCachedController.prefetch()
        await self.waitUntil { prefetchedCachedController.phase == .offered }
        XCTAssertTrue(prefetchedCached.readCount == 1 && prefetchedCached.downloads == 0 && prefetchedCached.loads == 0)

        let cancelledPrefetch = OnboardingAISetupHarness()
        cancelledPrefetch.pauseDownload = true
        let cancelledPrefetchController = cancelledPrefetch.controller()
        cancelledPrefetchController.prefetch()
        await self.waitUntil { cancelledPrefetch.downloadContinuation != nil }
        cancelledPrefetchController.enable { _ in XCTFail("Cancelled activation") }
        cancelledPrefetchController.cancel()
        XCTAssertTrue(cancelledPrefetchController.phase == .cancelling && cancelledPrefetchController.progress == nil)
        cancelledPrefetch.downloadContinuation?.resume()
        await self.waitUntil { cancelledPrefetchController.phase == .offered }
        cancelledPrefetch.pauseDownload = false
        cancelledPrefetchController.enable { _ in cancelledPrefetch.commits += 1 }
        await self.waitUntil { cancelledPrefetchController.phase == .ready }
        XCTAssertTrue(cancelledPrefetch.downloads == 2 && cancelledPrefetch.loads == 1 && cancelledPrefetch.commits == 1)
    }

    // Turns red if leaving onboarding cancels a "set up later" download, or an installed
    // model is downloaded again on activation.
    func testSetUpLaterOutlivesOnboardingAndCachedModelSkipsDownload() async {
        let cached = OnboardingAISetupHarness()
        let deferred = OnboardingAISetupHarness()
        deferred.pauseDownload = true
        var deferredController: OnboardingAISetupController? = deferred.controller()
        weak var retainedDownload = deferredController
        deferredController?.setUpLater()
        await self.waitUntil { deferred.downloadContinuation != nil }
        deferredController?.leavePage()
        deferredController = nil
        XCTAssertTrue(retainedDownload != nil, "Download survives onboarding dismissal")
        deferred.downloadContinuation?.resume()
        deferred.progressCallback = nil
        await self.waitUntil { retainedDownload == nil }
        XCTAssertTrue(deferred.downloads == 1 && deferred.loads == 0 && deferred.commits == 0)

        cached.installed = true
        let cachedController = cached.controller()
        cachedController.refresh()
        await self.waitUntil { cachedController.phase == .offered }
        cachedController.enable { _ in cached.commits += 1 }
        await self.waitUntil { cachedController.phase == .ready }
        XCTAssertTrue(cached.downloads == 0 && cached.loads == 1 && cached.commits == 1)
    }

    // Turns red if cancelling mid-download or mid-load still commits, lets new work overlap
    // the cancelled work, or shows progress from the old operation.
    func testCancellationDuringDownloadOrLoad() async {
        for cancelDuringLoad in [false, true] {
            let harness = OnboardingAISetupHarness()
            harness.pauseDownload = !cancelDuringLoad
            harness.pauseLoad = cancelDuringLoad
            let operation = harness.controller()
            operation.refresh()
            await self.waitUntil { operation.phase == .offered }
            operation.enable { _ in harness.commits += 1 }
            await self.waitUntil { cancelDuringLoad ? harness.loadContinuation != nil : harness.downloadContinuation != nil }
            operation.cancel()
            operation.cancel()
            XCTAssertTrue(operation.phase == .cancelling && operation.progress == nil)
            operation.enable { _ in XCTFail("Cannot overlap cancelled work") }
            await harness.progressCallback?(.init(fraction: 0.9, status: "late", bytes: nil))
            XCTAssertTrue(operation.progress == nil)
            harness.downloadContinuation?.resume()
            harness.loadContinuation?.resume()
            await self.waitUntil { operation.phase == .offered }
            XCTAssertTrue(harness.commits == 0 && operation.errorMessage == nil)
            XCTAssertTrue(harness.loads == (cancelDuringLoad ? 1 : 0))
            let oldProgress = harness.progressCallback
            harness.pauseDownload = false
            harness.pauseLoad = false
            operation.enable { _ in harness.commits += 1 }
            await self.waitUntil { operation.phase == .ready }
            await oldProgress?(.init(fraction: 0.2, status: "old operation", bytes: nil))
            XCTAssertTrue(operation.progress == nil && harness.commits == 1)
        }
    }

    // Turns red if a failed download, load or recommendation strands the controller, or a
    // rejected commit is treated as success.
    func testFailuresLeaveOfferAndRetrySucceeds() async {
        for downloadFailure in [true, false] {
            let harness = OnboardingAISetupHarness()
            harness.failDownload = downloadFailure
            harness.failLoad = !downloadFailure
            let operation = harness.controller()
            operation.refresh()
            await self.waitUntil { operation.phase == .offered }
            operation.enable { _ in harness.commits += 1 }
            await self.waitUntil { operation.errorMessage != nil }
            XCTAssertTrue(operation.phase == .offered && harness.commits == 0 && operation.progress == nil)
            harness.failDownload = false
            harness.failLoad = false
            operation.enable { _ in harness.commits += 1 }
            await self.waitUntil { operation.phase == .ready }
            XCTAssertTrue(harness.commits == 1)
        }

        let unavailable = OnboardingAISetupHarness()
        unavailable.failRecommendation = true
        let missing = unavailable.controller()
        missing.refresh()
        await self.waitUntil { missing.phase == .unavailable }
        XCTAssertTrue(unavailable.downloads == 0 && unavailable.commits == 0)
        unavailable.failRecommendation = false
        missing.refresh()
        await self.waitUntil { missing.phase == .offered }
        missing.enable { _ in throw OnboardingAISetupHarness.Failure.simulated }
        await self.waitUntil { missing.errorMessage != nil }
        XCTAssertTrue(missing.phase == .offered && unavailable.commits == 0)
    }
}
