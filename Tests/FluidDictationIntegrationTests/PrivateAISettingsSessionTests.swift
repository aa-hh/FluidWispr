@testable import FluidVoice_Debug
import Foundation
import XCTest

/// The Private AI settings card's carousel math, its one-at-a-time work slot, and the model
/// update transaction that commits only a verified download.
@MainActor
final class PrivateAISettingsSessionTests: XCTestCase {
    private enum Failure: Error { case expected }

    // Turns red if the carousel invents a neighbor, stops wrapping, or places cards on the wrong side.
    func testCarouselWrapsAndPlacesCardsAroundTheCurrentModel() {
        XCTAssertNil(PrivateAIModelCarouselNavigation.next(in: [], current: "missing", forward: true))
        XCTAssertEqual(PrivateAIModelCarouselNavigation.next(in: ["mini"], current: "mini", forward: false), "mini")
        XCTAssertEqual(PrivateAIModelCarouselNavigation.next(in: ["pico", "mini"], current: "mini", forward: true), "pico")
        XCTAssertEqual(PrivateAIModelCarouselNavigation.next(in: ["pico", "mini"], current: "pico", forward: false), "mini")
        XCTAssertEqual(PrivateAIModelCarouselNavigation.next(in: ["pico", "mini"], current: "deleted", forward: true), "pico")
        XCTAssertEqual(PrivateAIModelCarouselNavigation.position(of: "pico", in: ["pico", "mini", "full"], current: "mini"), -1)
        XCTAssertEqual(PrivateAIModelCarouselNavigation.position(of: "full", in: ["pico", "mini", "full"], current: "mini"), 1)
    }

    // Turns red if browsing models activates one, or a finished or foreign operation frees another's work slot.
    func testBrowsingNeverActivatesAndOnlyTheOwnerFreesTheSlot() {
        var session = PrivateAISettingsSession(selectedModelID: "mini")
        let initialRevision = session.revision
        for id in ["pico", "mini", "pico"] {
            session.preview(id)
        }
        XCTAssertEqual(session.previewModelID, "pico")
        XCTAssertEqual(session.selectedModelID, "mini")
        XCTAssertEqual(session.revision, initialRevision, "Browsing does not invalidate status reads")
        XCTAssertTrue(session.acceptsRead(initialRevision))

        XCTAssertTrue(session.select(session.previewModelID))
        XCTAssertEqual(session.selectedModelID, "pico")
        XCTAssertFalse(session.acceptsRead(initialRevision), "A status read for the old model is refused")

        let beforeOperation = session.revision
        guard let first = session.begin() else { return XCTFail("The first operation starts") }
        XCTAssertNil(session.begin())
        XCTAssertFalse(session.select("mini"), "Activation waits for running work")
        session.preview("mini")
        XCTAssertEqual(session.previewModelID, "mini")
        XCTAssertEqual(session.selectedModelID, "pico")
        XCTAssertFalse(session.acceptsRead(beforeOperation))

        session.finish(UUID())
        XCTAssertTrue(session.isBusy)
        session.finish(first)
        XCTAssertFalse(session.isBusy)
        XCTAssertFalse(session.acceptsRead(beforeOperation))

        guard let second = session.begin() else { return XCTFail("A second operation starts") }
        session.finish(first)
        XCTAssertTrue(session.isBusy, "A late finish from the first operation cannot free the second")
        session.finish(second)
        XCTAssertFalse(session.isBusy)
    }

    // Turns red if a verified update is not committed once, or a failed verification commits instead of rolling back.
    func testAnUpdateCommitsOnlyAfterVerification() async throws {
        var events: [String] = []
        let committed = try await PrivateAISettingsUpdateTransaction.run(
            update: { events.append("download"); return 7 },
            verify: { events.append("verify"); return true },
            commit: { token in XCTAssertEqual(token, 7); events.append("commit") },
            rollback: { _ in events.append("rollback") }
        )
        XCTAssertTrue(committed)
        XCTAssertEqual(events, ["download", "verify", "commit"])

        events = []
        let rejected = try await PrivateAISettingsUpdateTransaction.run(
            update: { events.append("download"); return 8 },
            verify: { events.append("verify"); return false },
            commit: { _ in events.append("commit") },
            rollback: { token in XCTAssertEqual(token, 8); events.append("rollback") }
        )
        XCTAssertFalse(rejected)
        XCTAssertEqual(events, ["download", "verify", "rollback"])
    }

    // Turns red if a failed download verifies, commits or rolls back, or leaves the work slot taken.
    func testAFailedDownloadStopsBeforeVerifying() async throws {
        var session = PrivateAISettingsSession(selectedModelID: "pico")
        var events: [String] = []
        guard let operation = session.begin() else { return XCTFail("The operation starts") }
        do {
            defer { session.finish(operation) }
            _ = try await PrivateAISettingsUpdateTransaction.run(
                update: { () async throws -> Int in events.append("download"); throw Failure.expected },
                verify: { events.append("verify"); return true },
                commit: { _ in events.append("commit") },
                rollback: { _ in events.append("rollback") }
            )
            XCTFail("The download error reaches the caller")
        } catch Failure.expected {}
        XCTAssertEqual(events, ["download"])
        XCTAssertFalse(session.isBusy)
        XCTAssertTrue(session.select("mini"))
    }

    // Turns red if cancelling after the download, or during verification, commits instead of rolling back.
    func testCancellingAnUpdateRollsBack() async throws {
        var events: [String] = []
        let afterDownload = Task { @MainActor in
            try await PrivateAISettingsUpdateTransaction.run(
                update: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    events.append("download")
                    return 9
                },
                verify: { events.append("verify"); return true },
                commit: { _ in events.append("commit") },
                rollback: { _ in events.append("rollback") }
            )
        }
        do {
            _ = try await afterDownload.value
            XCTFail("Cancellation reaches the caller")
        } catch is CancellationError {}
        XCTAssertEqual(events, ["download", "rollback"])

        events = []
        let duringVerification = Task { @MainActor in
            try await PrivateAISettingsUpdateTransaction.run(
                update: { 10 },
                verify: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return true
                },
                commit: { _ in events.append("commit") },
                rollback: { _ in events.append("rollback") }
            )
        }
        do {
            _ = try await duringVerification.value
            XCTFail("Cancellation reaches the caller")
        } catch is CancellationError {}
        XCTAssertEqual(events, ["rollback"])
    }

    // Turns red if the work slot frees, or a model can be activated, while a rollback is still running.
    func testTheSlotStaysTakenUntilRollbackFinishes() async throws {
        var session = PrivateAISettingsSession(selectedModelID: "mini")
        guard let operation = session.begin() else { return XCTFail("The operation starts") }
        var checkedDuringRollback = false
        _ = try await PrivateAISettingsUpdateTransaction.run(
            update: { 11 },
            verify: { false },
            commit: { _ in XCTFail("A failed verification never commits") },
            rollback: { _ in
                await Task.yield()
                XCTAssertTrue(session.isBusy)
                XCTAssertNil(session.begin())
                XCTAssertFalse(session.select("pico"))
                checkedDuringRollback = true
            }
        )
        XCTAssertTrue(checkedDuringRollback)
        session.finish(operation)
        XCTAssertFalse(session.isBusy)
    }
}
