@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Stands in for Command Mode and the menu bar. The agent call can leave a confirmation
/// waiting, and `afterProcess` runs at the point Escape would land as the call returns.
@MainActor
private final class VoiceCommandRecorder {
    var outputValid = true
    var leavesConfirmation = false
    var afterProcess: (() -> Void)?
    var requests: [String] = []
    var pendingCommand = false
    var processingUpdates: [Bool] = []
    var pendingOwners: [UInt64?] = []

    var flow: VoiceCommandFlow {
        VoiceCommandFlow(
            setProcessing: { self.processingUpdates.append($0) },
            process: { command, isOutputValid in
                self.requests.append(command)
                if isOutputValid(), self.leavesConfirmation { self.pendingCommand = true }
                self.afterProcess?()
            },
            cancelInvalidPendingCommand: { self.pendingCommand = false },
            hasPendingCommand: { self.pendingCommand },
            setPendingConfirmationOwner: { self.pendingOwners.append($0) }
        )
    }

    func run() async {
        await self.flow.run("delete the build folder", lifecycleID: 7, isOutputValid: { self.outputValid })
    }
}

@MainActor
final class VoiceCommandFlowTests: XCTestCase {
    // Turns red if a voice command whose output was already cancelled reaches Command Mode or the menu bar.
    func testCancelledOutputSendsNothing() async {
        let recorder = VoiceCommandRecorder()
        recorder.outputValid = false
        await recorder.run()
        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertTrue(recorder.processingUpdates.isEmpty)
    }

    // Turns red if a valid voice command that needs confirmation stops recording its recording as the owner.
    func testConfirmationIsOwnedByTheRecording() async {
        let recorder = VoiceCommandRecorder()
        recorder.leavesConfirmation = true
        await recorder.run()
        XCTAssertEqual(recorder.requests, ["delete the build folder"])
        XCTAssertTrue(recorder.pendingCommand)
        XCTAssertEqual(recorder.pendingOwners, [7])
        XCTAssertEqual(recorder.processingUpdates, [true, false])
    }

    // Turns red if a finished command with nothing to confirm leaves an old owner in place.
    func testFinishedCommandClearsTheOwner() async {
        let recorder = VoiceCommandRecorder()
        await recorder.run()
        XCTAssertEqual(recorder.pendingOwners, [nil])
        XCTAssertEqual(recorder.processingUpdates, [true, false])
    }

    // Turns red if Escape as the agent returns leaves a hidden confirmation, records an owner, or touches the indicator again.
    func testEscapeAsTheAgentReturnsDropsTheConfirmation() async {
        let recorder = VoiceCommandRecorder()
        recorder.leavesConfirmation = true
        recorder.afterProcess = { recorder.outputValid = false }
        await recorder.run()
        XCTAssertFalse(recorder.pendingCommand)
        XCTAssertTrue(recorder.pendingOwners.isEmpty)
        XCTAssertEqual(recorder.processingUpdates, [true])
    }

    // Turns red if the notch follow-up field clears a rejected draft, or wipes a new draft typed while the old one was sending.
    func testFollowUpDraftClearsOnlyAcceptedUnchangedText() async {
        for accepted in [true, false] {
            for typesNewDraft in [true, false] {
                var field = "follow-up"
                var sent: [String] = []
                await FollowUpDraft.submit(
                    field,
                    send: { text in
                        sent.append(text)
                        if typesNewDraft { field = "new draft" }
                        return accepted
                    },
                    currentText: { field },
                    clear: { field = "" }
                )
                let expected = typesNewDraft ? "new draft" : (accepted ? "" : "follow-up")
                XCTAssertEqual(sent, ["follow-up"])
                XCTAssertEqual(field, expected, "accepted: \(accepted), new draft: \(typesNewDraft)")
            }
        }
    }
}
