@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Records what the voice edit flow asked for. The model call, focus restore and paste each
/// wait on a continuation, so a test can cancel the output while the flow is parked there.
@MainActor
private final class VoiceEditRecorder {
    var outputValid = true
    var originalText = "original"
    var rewrittenText = ""
    var restoreFocus = true
    var deliveryFails = false
    var requests = 0
    var clears = 0
    var restores = 0
    var deliveries = 0
    var writes = 0
    var failures: [TextDeliveryFailure] = []
    var hides = 0
    var finishes = 0
    var dropped = 0
    var reply = "rewrite"
    var failedRetries: [@MainActor () -> Void] = []
    var modelReply: CheckedContinuation<Void, Never>?
    var focusReply: CheckedContinuation<Bool, Never>?
    var deliveryReply: CheckedContinuation<Void, Never>?

    var flow: VoiceEditFlow {
        VoiceEditFlow(
            setPromptAppBundleID: { _ in },
            originalText: { self.originalText },
            requestRewrite: { _ in
                self.requests += 1
                await withCheckedContinuation { self.modelReply = $0 }
                self.rewrittenText = self.reply
            },
            rewrittenText: { self.rewrittenText },
            clearRewrite: {
                self.clears += 1
                self.originalText = ""
                self.rewrittenText = ""
            },
            setProcessing: { _ in },
            finishWithoutResult: { self.finishes += 1 },
            typingTarget: { (pid: 1, shouldRestoreOriginalFocus: self.restoreFocus) },
            restoreTarget: { _, isOutputValid in
                self.restores += 1
                guard isOutputValid() else { return false }
                let restored = await withCheckedContinuation { self.focusReply = $0 }
                return restored && isOutputValid()
            },
            deliver: { _, _, isOutputValid in
                self.deliveries += 1
                await withCheckedContinuation { self.deliveryReply = $0 }
                guard isOutputValid() else { return .cancelled }
                if self.deliveryFails { return .recoverableFailure(.pasteCommandFailed) }
                self.writes += 1
                return .commandPosted
            },
            showDeliveryFailure: { failure, _ in self.failures.append(failure) },
            hideOverlay: { self.hides += 1 },
            dropFailedExchange: { self.dropped += 1 },
            showRewriteFailed: { self.failedRetries.append($0) }
        )
    }

    func start() -> Task<Void, Never> {
        let flow = self.flow
        return Task { await flow.run("make it shorter", appBundleID: "editor", isOutputValid: { self.outputValid }) }
    }

    func waitUntil(_ reached: () -> Bool) async {
        for _ in 0..<10_000 where !reached() {
            await Task.yield()
        }
        XCTAssertTrue(reached(), "The flow never reached the expected step")
    }
}

@MainActor
final class VoiceEditFlowTests: XCTestCase {
    // Turns red if an empty rewrite stops waiting in the pill's bubble, still tries to paste, or a click on the bubble stops
    // asking for the rewrite again or asks without first dropping the failed exchange.
    func testEmptyRewriteWaitsInTheBubbleAndRetries() async {
        let recorder = VoiceEditRecorder()
        recorder.reply = ""
        let task = recorder.start()
        await recorder.waitUntil { recorder.modelReply != nil }
        recorder.modelReply?.resume()
        await task.value

        XCTAssertEqual(recorder.finishes, 1)
        XCTAssertEqual(recorder.failedRetries.count, 1)
        XCTAssertEqual(recorder.restores, 0)
        XCTAssertEqual(recorder.deliveries, 0)

        recorder.modelReply = nil
        XCTAssertEqual(recorder.dropped, 0)
        recorder.failedRetries[0]()
        XCTAssertEqual(recorder.dropped, 1)
        await recorder.waitUntil { recorder.modelReply != nil }
        XCTAssertEqual(recorder.requests, 2)
        recorder.modelReply?.resume()
        await recorder.waitUntil { recorder.failedRetries.count == 2 }
    }

    // Turns red if the flow calls the model after Escape already cancelled the output.
    func testCancelledOutputSkipsTheModel() async {
        let recorder = VoiceEditRecorder()
        recorder.outputValid = false
        await recorder.start().value
        XCTAssertEqual(recorder.requests, 0)
        XCTAssertEqual(recorder.clears, 0)
    }

    // Turns red if Escape during the model call still restores focus, pastes, shows a failure, or leaves rewrite state behind.
    func testEscapeDuringModelCallStopsEverything() async {
        let recorder = VoiceEditRecorder()
        let task = recorder.start()
        await recorder.waitUntil { recorder.modelReply != nil }
        recorder.outputValid = false
        recorder.modelReply?.resume()
        await task.value

        XCTAssertEqual(recorder.restores, 0)
        XCTAssertEqual(recorder.deliveries, 0)
        XCTAssertTrue(recorder.failures.isEmpty)
        XCTAssertEqual(recorder.hides, 0)
        XCTAssertEqual(recorder.clears, 1)
        XCTAssertTrue(recorder.rewrittenText.isEmpty)
    }

    // Turns red if Escape during focus restore lets the flow paste or show a failure, whichever way the restore ends.
    func testEscapeDuringFocusRestoreStopsDelivery() async {
        for restored in [true, false] {
            let recorder = VoiceEditRecorder()
            let task = recorder.start()
            await recorder.waitUntil { recorder.modelReply != nil }
            recorder.modelReply?.resume()
            await recorder.waitUntil { recorder.focusReply != nil }
            recorder.outputValid = false
            recorder.focusReply?.resume(returning: restored)
            await task.value

            XCTAssertEqual(recorder.deliveries, 0, "restored: \(restored)")
            XCTAssertTrue(recorder.failures.isEmpty, "restored: \(restored)")
            XCTAssertEqual(recorder.hides, 0, "restored: \(restored)")
            XCTAssertEqual(recorder.clears, 1, "restored: \(restored)")
        }
    }

    // Turns red if a failed focus restore stops showing the target-restore failure, or pastes anyway.
    func testFailedFocusRestoreShowsFailureWithoutPasting() async {
        let recorder = VoiceEditRecorder()
        let task = recorder.start()
        await recorder.waitUntil { recorder.modelReply != nil }
        recorder.modelReply?.resume()
        await recorder.waitUntil { recorder.focusReply != nil }
        recorder.focusReply?.resume(returning: false)
        await task.value

        XCTAssertEqual(recorder.deliveries, 0)
        XCTAssertEqual(recorder.failures, [.targetRestoreFailed])
        XCTAssertEqual(recorder.hides, 0)
    }

    // Turns red if a cancelled paste writes or hides, a successful one stops clearing and hiding,
    // or a failed one hides the overlay or throws away the rewrite the failure card offers to copy.
    func testDeliveryOutcomes() async {
        for outcome in ["cancel", "success", "failure"] {
            let recorder = VoiceEditRecorder()
            recorder.restoreFocus = false
            recorder.deliveryFails = outcome == "failure"
            let task = recorder.start()
            await recorder.waitUntil { recorder.modelReply != nil }
            recorder.modelReply?.resume()
            await recorder.waitUntil { recorder.deliveryReply != nil }
            if outcome == "cancel" { recorder.outputValid = false }
            recorder.deliveryReply?.resume()
            await task.value

            XCTAssertEqual(recorder.restores, 0, outcome)
            XCTAssertEqual(recorder.writes, outcome == "success" ? 1 : 0, outcome)
            XCTAssertEqual(recorder.hides, outcome == "success" ? 1 : 0, outcome)
            XCTAssertEqual(recorder.failures, outcome == "failure" ? [.pasteCommandFailed] : [], outcome)
            XCTAssertEqual(recorder.clears, outcome == "failure" ? 0 : 1, outcome)
        }
    }

    // Turns red if an empty model result stops closing the overlay or starts pasting.
    func testEmptyRewriteFinishesWithoutPasting() async {
        let recorder = VoiceEditRecorder()
        let flow = VoiceEditFlow(
            setPromptAppBundleID: { _ in },
            originalText: { "" },
            requestRewrite: { _ in recorder.requests += 1 },
            rewrittenText: { "" },
            clearRewrite: { recorder.clears += 1 },
            setProcessing: { _ in },
            finishWithoutResult: { recorder.finishes += 1 },
            typingTarget: { (pid: nil, shouldRestoreOriginalFocus: false) },
            restoreTarget: { _, _ in true },
            deliver: { _, _, _ in
                recorder.deliveries += 1
                return .commandPosted
            },
            showDeliveryFailure: { failure, _ in recorder.failures.append(failure) },
            hideOverlay: { recorder.hides += 1 }
        )
        await flow.run("hello there", appBundleID: "editor", isOutputValid: { true })

        XCTAssertEqual(recorder.requests, 1)
        XCTAssertEqual(recorder.finishes, 1)
        XCTAssertEqual(recorder.deliveries, 0)
        XCTAssertEqual(recorder.hides, 0)
    }
}
