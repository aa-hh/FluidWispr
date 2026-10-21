import AppKit
@testable import FluidVoice_Debug
import XCTest

// Runs the real PasteDeliveryCoordinator and SystemPasteboardManager on private, named
// pasteboards. Only command posting and some pasteboard failures are injected, so no keys
// are sent and the system clipboard is never touched.
@MainActor
final class ClipboardBackupTests: XCTestCase {
    private var boards: [NSPasteboard] = []

    override func tearDown() {
        for board in self.boards {
            board.releaseGlobally()
        }
        self.boards = []
        super.tearDown()
    }

    private func makeBoard() -> NSPasteboard {
        let board = NSPasteboard(name: .init("fluidvoice.clipboard-backup-tests.\(UUID().uuidString)"))
        self.boards.append(board)
        return board
    }

    // Turns red if restoring a file copy loses its URL, existing text or small payloads, or an
    // oversized payload is kept instead of falling back to the file name.
    func testOversizedFileFallsBackToFileName() throws {
        for existingText in [nil, "original label"] as [String?] {
            for oversized in [false, true] {
                let board = self.makeBoard()
                let fileURL = URL(fileURLWithPath: "/tmp/Report with spaces.pdf")
                let payloadType = NSPasteboard.PasteboardType("com.fluidvoice.tests.payload")
                let item = NSPasteboardItem()
                XCTAssertTrue(item.setString(fileURL.absoluteString, forType: .fileURL))
                XCTAssertTrue(item.setData(Data(count: oversized ? SystemPasteboardManager.maximumRepresentationBytes + 1 : 16), forType: payloadType))
                if let existingText { XCTAssertTrue(item.setString(existingText, forType: .string)) }
                XCTAssertTrue(board.writeObjects([item]))
                let manager = SystemPasteboardManager(pasteboard: board)
                let snapshot = try XCTUnwrap(manager.captureSnapshot())
                XCTAssertTrue(manager.writeTemporaryText("dictated", sessionID: "filename-test"))
                XCTAssertTrue(manager.restore(snapshot))
                let label = "text=\(existingText ?? "nil") oversized=\(oversized)"
                XCTAssertEqual(board.string(forType: .fileURL).flatMap(URL.init(string:)), fileURL, label)
                XCTAssertEqual(board.string(forType: .string), existingText ?? (oversized ? fileURL.lastPathComponent : nil), label)
                XCTAssertEqual(board.data(forType: payloadType) == nil, oversized, label)
                if oversized { XCTAssertNil(snapshot.items.first?.portableImage, label) }
            }
        }
    }

    // Turns red if a failed snapshot, write or paste command loses the user's clipboard, a newer
    // user copy is overwritten, or an enabled transcript backup is left marked as temporary.
    func testDeliveryRestoresOrBacksUpClipboard() async {
        for keepBackup in [false, true] {
            for scenario in Scenario.allCases {
                let board = self.makeBoard()
                let manager = InjectedPasteboard(board: board, scenario: scenario)
                XCTAssertTrue(manager.base.writeIntentionalText("old clipboard"))
                let poster = InjectedCommandPoster(succeeds: scenario != .commandFailure && scenario != .externalCopyDuringFailedPost)
                if scenario == .externalCopyDuringFailedPost {
                    poster.onPost = { _ = manager.base.writeIntentionalText("new user copy") }
                }
                let coordinator = PasteDeliveryCoordinator(pasteboard: manager, commandPoster: poster, settlementDelayNanoseconds: .max)
                let result = await coordinator.deliver("dictated text", preserveTranscriptOnClipboard: keepBackup)
                if scenario == .newerUserCopy {
                    XCTAssertTrue(manager.base.writeIntentionalText("new user copy"))
                }
                coordinator.runPendingSettlementForTesting()

                let expectedResult: TextDeliveryResult = switch scenario {
                case .snapshotFailure: .recoverableFailure(.clipboardSnapshotFailed)
                case .writeFailure, .earlyWriteFailure, .externalCopyDuringFailedWrite: .recoverableFailure(.clipboardWriteFailed)
                case .commandFailure, .externalCopyDuringFailedPost: .recoverableFailure(.pasteCommandFailed)
                case .success, .newerUserCopy: .commandPosted
                }
                let hasNewerCopy = [.newerUserCopy, .externalCopyDuringFailedPost, .externalCopyDuringFailedWrite].contains(scenario)
                let expectedText = hasNewerCopy ? "new user copy" : (keepBackup ? "dictated text" : "old clipboard")
                let expectedPosts = [.snapshotFailure, .writeFailure, .earlyWriteFailure, .externalCopyDuringFailedWrite].contains(scenario) ? 0 : 1
                // Restored old content is marked transient to avoid duplicate clipboard-manager
                // entries. An enabled transcript backup must be permanent.
                let isTemporary = board.types?.contains(.init("org.nspasteboard.TransientType")) == true
                let label = "backup=\(keepBackup) scenario=\(scenario.rawValue)"
                XCTAssertEqual(result, expectedResult, label)
                XCTAssertEqual(board.string(forType: .string), expectedText, label)
                XCTAssertEqual(poster.postCount, expectedPosts, label)
                XCTAssertTrue(!keepBackup || !isTemporary, "\(label): the backup must not be temporary")
                XCTAssertEqual(manager.intentionalWrites, keepBackup && !hasNewerCopy ? 1 : 0, label)
            }
        }
    }

    // Turns red if preparing a paste copies the transcript when focus can be restored, or touches
    // the clipboard at all when no backup is wanted.
    func testPreparationOnlyCopiesWhenFocusCannotReturn() async {
        for backup in [false, true] {
            for returnToStart in [false, true] {
                for focusedPID: Int32? in [200, nil] {
                    let board = self.makeBoard()
                    let manager = InjectedPasteboard(board: board, scenario: .success)
                    XCTAssertTrue(manager.base.writeIntentionalText("old clipboard"))
                    let originalChangeCount = manager.changeCount
                    let poster = InjectedCommandPoster(succeeds: true)
                    let coordinator = PasteDeliveryCoordinator(pasteboard: manager, commandPoster: poster)
                    let target = DictationTargetPolicy.resolve(
                        returnToStartingField: returnToStart,
                        focusedPID: focusedPID,
                        ownPID: 999,
                        originalPID: 100,
                        originalFieldIsFocused: false
                    )
                    let ready = await coordinator.prepareForDelivery("dictated text", preserveTranscriptOnClipboard: backup) {
                        // Restoring focus always fails here, so the backup path is exercised.
                        !target.shouldRestoreOriginalFocus
                    }
                    let expectedCopy = backup && target.shouldRestoreOriginalFocus
                    let label = "backup=\(backup) returnToStart=\(returnToStart) externalFocus=\(focusedPID != nil)"
                    XCTAssertEqual(ready, !target.shouldRestoreOriginalFocus, label)
                    XCTAssertEqual(board.string(forType: .string), expectedCopy ? "dictated text" : "old clipboard", label)
                    XCTAssertEqual(manager.intentionalWrites, expectedCopy ? 1 : 0, label)
                    XCTAssertEqual(poster.postCount, 0, label)
                    if !expectedCopy {
                        XCTAssertEqual(manager.changeCount, originalChangeCount, "\(label): the clipboard must be untouched")
                    }
                }
            }
        }
    }

    // Turns red if a queued backup copy overwrites the first paste before it settles, or wins
    // over a newer user copy.
    func testQueuedBackupWaitsForEarlierPaste() async {
        for backup in [false, true] {
            for externalCopy in [false, true] {
                let board = self.makeBoard()
                let manager = InjectedPasteboard(board: board, scenario: .success)
                XCTAssertTrue(manager.base.writeIntentionalText("old clipboard"))
                let poster = InjectedCommandPoster(succeeds: true)
                let coordinator = PasteDeliveryCoordinator(pasteboard: manager, commandPoster: poster, settlementDelayNanoseconds: .max)
                _ = await coordinator.deliver("first", preserveTranscriptOnClipboard: false)
                var started = false
                let pending = Task { @MainActor in
                    started = true
                    return await coordinator.copyBackup("second", enabled: backup)
                }
                for _ in 0..<100 where !started {
                    await Task.yield()
                }
                let label = "backup=\(backup) newerUserCopy=\(externalCopy)"
                XCTAssertEqual(board.string(forType: .string), "first", "\(label): the first paste must stay on the clipboard until it settles")
                if externalCopy { XCTAssertTrue(manager.base.writeIntentionalText("new user copy")) }
                coordinator.runPendingSettlementForTesting()
                let copied = await pending.value
                let expected = externalCopy ? "new user copy" : (backup ? "second" : "old clipboard")
                XCTAssertEqual(board.string(forType: .string), expected, label)
                XCTAssertEqual(copied, backup && !externalCopy, label)
                XCTAssertEqual(poster.postCount, 1, label)
                XCTAssertEqual(manager.intentionalWrites, backup && !externalCopy ? 1 : 0, label)
            }
        }
    }

    // Turns red if a backup prepared before a newer paste, copy or user copy overwrites that
    // newer clipboard content when focus restoration finally fails.
    func testStalePreparationLosesToNewerOutput() async {
        for newerOutput in ["user copy", "paste", "copy only"] {
            let board = self.makeBoard()
            let manager = InjectedPasteboard(board: board, scenario: .success)
            XCTAssertTrue(manager.base.writeIntentionalText("old clipboard"))
            let coordinator = PasteDeliveryCoordinator(
                pasteboard: manager,
                commandPoster: InjectedCommandPoster(succeeds: true),
                settlementDelayNanoseconds: .max
            )
            let ready = await coordinator.prepareForDelivery("stale text", preserveTranscriptOnClipboard: true) {
                if newerOutput == "paste" {
                    _ = await coordinator.deliver("newer text", preserveTranscriptOnClipboard: true)
                    coordinator.runPendingSettlementForTesting()
                } else if newerOutput == "copy only" {
                    _ = await coordinator.copyBackup("newer text", enabled: true)
                } else {
                    _ = manager.base.writeIntentionalText("newer text")
                }
                return false
            }
            XCTAssertFalse(ready, newerOutput)
            XCTAssertEqual(board.string(forType: .string), "newer text", newerOutput)
        }
    }
}

private enum Scenario: String, CaseIterable {
    case success, snapshotFailure, writeFailure, earlyWriteFailure, commandFailure, newerUserCopy
    case externalCopyDuringFailedWrite, externalCopyDuringFailedPost
}

@MainActor
private final class InjectedCommandPoster: PasteCommandPosting {
    let succeeds: Bool
    private(set) var postCount = 0
    var onPost: (() -> Void)?

    init(succeeds: Bool) {
        self.succeeds = succeeds
    }

    func postGlobalPasteCommand() async -> Bool {
        self.postCount += 1
        self.onPost?()
        return self.succeeds
    }
}

@MainActor
private final class InjectedPasteboard: PasteboardManaging {
    let base: SystemPasteboardManager
    let scenario: Scenario
    var changeCount: Int { self.base.changeCount }
    private(set) var intentionalWrites = 0

    init(board: NSPasteboard, scenario: Scenario) {
        self.base = SystemPasteboardManager(pasteboard: board)
        self.scenario = scenario
    }

    func captureSnapshot() -> PasteboardSnapshot? {
        self.scenario == .snapshotFailure ? nil : self.base.captureSnapshot()
    }

    func writeTemporaryText(_ text: String, sessionID: String) -> Bool {
        if self.scenario == .earlyWriteFailure { return false }
        let written = self.base.writeTemporaryText(text, sessionID: sessionID)
        if self.scenario == .externalCopyDuringFailedWrite {
            _ = self.base.writeIntentionalText("new user copy")
            return false
        }
        // Covers cleanup after a write that touched the clipboard but reports failure.
        return self.scenario == .writeFailure ? false : written
    }

    func writeIntentionalText(_ text: String) -> Bool {
        self.intentionalWrites += 1
        return self.base.writeIntentionalText(text)
    }

    func isOwned(sessionID: String, expectedText: String) -> Bool {
        self.base.isOwned(sessionID: sessionID, expectedText: expectedText)
    }

    func restore(_ snapshot: PasteboardSnapshot) -> Bool {
        self.base.restore(snapshot)
    }

    func restoreTemporarySnapshot(_ snapshot: PasteboardSnapshot, sessionID: String, expectedText: String) -> Bool {
        self.base.restoreTemporarySnapshot(snapshot, sessionID: sessionID, expectedText: expectedText)
    }
}
