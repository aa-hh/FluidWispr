@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Preferences that count writes, so a test can tell an unchanged save from a rewrite.
private final class CountingDefaults: UserDefaults {
    var writes = 0
    var writtenKeys: [String] = []

    override func set(_ value: Any?, forKey defaultName: String) {
        self.writes += 1
        self.writtenKeys.append(defaultName)
        super.set(value, forKey: defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        self.writes += 1
        self.writtenKeys.append(defaultName)
        super.removeObject(forKey: defaultName)
    }

    func resetCounts() {
        self.writes = 0
        self.writtenKeys = []
    }
}

/// Command Mode's chat sessions: switching, creating, deleting, archiving and restoring keep the
/// right conversation, reset per-chat progress, and only write history when something changed.
@MainActor
final class CommandSessionBoundaryTests: XCTestCase {
    private var suiteName = ""
    private var defaults: CountingDefaults!
    private var store: ChatHistoryStore!

    private struct Snapshot: Equatable {
        let currentID: String?
        let conversation: [CommandModeService.Message]
        let transient: CommandModeService.TransientState
        let isProcessing: Bool
        let sessions: [ChatSession]
        let storeCurrentID: String?
        let writes: Int
        let notch: [String]
    }

    override func tearDown() async throws {
        if !self.suiteName.isEmpty { self.defaults?.removePersistentDomain(forName: self.suiteName) }
        NotchContentState.shared.clearCommandOutput()
        self.store = nil
        self.defaults = nil
    }

    private var notch: [String] { NotchContentState.shared.commandConversationHistory.map(\.content) }

    /// Whether the app's overlay settings route Command Mode output to the notch on this machine.
    private var notchSyncs: Bool { NotchOverlayManager.shared.shouldSyncCommandConversationToNotch }

    private func snapshot(_ service: CommandModeService) -> Snapshot {
        Snapshot(
            currentID: service.currentChatID,
            conversation: service.conversationHistory,
            transient: service.transientState,
            isProcessing: service.isProcessing,
            sessions: self.store.sessions,
            storeCurrentID: self.store.currentChatID,
            writes: self.defaults.writes,
            notch: self.notch
        )
    }

    /// A store on its own suite, loaded from these saved sessions, with write counts reset.
    private func makeStore(sessions: [ChatSession], currentChatID: String) throws {
        if !self.suiteName.isEmpty { self.defaults?.removePersistentDomain(forName: self.suiteName) }
        self.suiteName = "CommandSessionBoundaryTests.\(UUID().uuidString)"
        self.defaults = try XCTUnwrap(CountingDefaults(suiteName: self.suiteName)) // isolation-ok: own suite, removed in tearDown
        try self.defaults.set(JSONEncoder().encode(sessions), forKey: "CommandModeChatSessions")
        self.defaults.set(currentChatID, forKey: "CommandModeCurrentChatID")
        self.store = ChatHistoryStore(defaults: self.defaults)
        self.defaults.resetCounts()
    }

    /// Three saved chats, "active" open with one unsaved answer and leftover progress.
    private func fixture() throws -> CommandModeService {
        let sessions = ["active", "recent", "older"].enumerated().map { index, id in
            ChatSession(
                id: id,
                title: id,
                updatedAt: Date(timeIntervalSince1970: Double(300 - index * 100)),
                messages: [.init(role: .user, content: "\(id) saved message")]
            )
        }
        try self.makeStore(sessions: sessions, currentChatID: "active")
        NotchContentState.shared.clearCommandOutput()
        let service = CommandModeService(chatStore: self.store)
        service.conversationHistory.append(.init(role: .assistant, content: "unsaved active answer"))
        service.seedTransientState()
        NotchContentState.shared.addCommandMessage(role: .assistant, content: "active notch answer")
        return service
    }

    // Turns red if deleting another chat saves, retitles or reloads the open one, or skips saving the removal.
    func testDeletingAnotherChatKeepsTheOpenOne() throws {
        let service = try self.fixture()
        let before = self.snapshot(service)

        XCTAssertTrue(service.deleteChat(id: "older"))

        let after = self.snapshot(service)
        XCTAssertEqual(after.currentID, before.currentID)
        XCTAssertEqual(after.storeCurrentID, before.storeCurrentID)
        XCTAssertEqual(after.conversation, before.conversation)
        XCTAssertEqual(after.transient, before.transient)
        XCTAssertEqual(self.store.currentSession, before.sessions.first { $0.id == "active" })
        XCTAssertEqual(after.sessions.map(\.id), ["active", "recent"])
        XCTAssertEqual(after.notch, before.notch)
        XCTAssertGreaterThan(after.writes, before.writes)
    }

    // Turns red if deleting the open chat keeps its progress, saves it back, or opens anything but the newest remaining chat.
    func testDeletingTheOpenChatOpensTheNextOne() throws {
        let service = try self.fixture()

        service.deleteCurrentChat()

        XCTAssertEqual(service.currentChatID, "recent")
        XCTAssertEqual(self.store.currentChatID, "recent")
        XCTAssertEqual(service.conversationHistory.map(\.content), ["recent saved message"])
        XCTAssertEqual(service.transientState, CommandModeService.TransientState())
        XCTAssertFalse(self.store.sessions.contains { $0.id == "active" })
        if self.notchSyncs { XCTAssertEqual(self.notch, ["recent saved message"]) }
    }

    // Turns red if deleting the last chat leaves no chat open, or the new chat starts with old messages or progress.
    func testDeletingTheLastChatOpensAnEmptyOne() throws {
        let service = try self.fixture()
        XCTAssertTrue(service.deleteChat(id: "older"))
        XCTAssertTrue(service.deleteChat(id: "recent"))
        XCTAssertTrue(service.deleteChat(id: "active"))

        XCTAssertEqual(self.store.sessions.count, 1)
        XCTAssertNotEqual(service.currentChatID, "active")
        XCTAssertEqual(service.currentChatID, self.store.currentChatID)
        XCTAssertTrue(service.conversationHistory.isEmpty)
        XCTAssertEqual(service.transientState, CommandModeService.TransientState())
        if self.notchSyncs { XCTAssertTrue(self.notch.isEmpty) }
    }

    // Turns red if a running command or a pending approval stops blocking switch, delete or new chat.
    func testRunningWorkBlocksChatChanges() throws {
        for pendingApproval in [false, true] {
            let service = try self.fixture()
            if pendingApproval {
                service.pendingCommand = .init(id: "approval", command: "test command", workingDirectory: nil, purpose: "test")
            } else {
                service.isProcessing = true
            }
            let before = self.snapshot(service)

            service.createNewChat()
            XCTAssertFalse(service.switchToChat(id: "recent"))
            XCTAssertFalse(service.deleteChat(id: "older"))
            XCTAssertFalse(service.deleteChat(id: "active"))
            service.deleteCurrentChat()

            XCTAssertEqual(self.snapshot(service), before, "pending approval: \(pendingApproval)")
        }
    }

    // Turns red if a missing or already deleted chat ID can switch, delete, or write anything.
    func testMissingAndRepeatedActionsChangeNothing() throws {
        let service = try self.fixture()
        let before = self.snapshot(service)
        for id in ["missing", "", "missing"] {
            XCTAssertFalse(service.switchToChat(id: id), id)
            XCTAssertFalse(service.deleteChat(id: id), id)
        }
        XCTAssertTrue(service.switchToChat(id: "active"))
        XCTAssertEqual(self.snapshot(service), before)

        XCTAssertTrue(service.deleteChat(id: "older"))
        let afterDelete = self.snapshot(service)
        XCTAssertFalse(service.deleteChat(id: "older"))
        XCTAssertFalse(service.switchToChat(id: "older"))
        XCTAssertEqual(self.snapshot(service), afterDelete)
    }

    // Turns red if switching or starting a chat keeps old progress, or drops the unsaved answer of the chat being left.
    func testSwitchingAndNewChatResetProgress() throws {
        let service = try self.fixture()

        XCTAssertTrue(service.switchToChat(id: "recent"))
        XCTAssertEqual(service.currentChatID, "recent")
        XCTAssertEqual(service.conversationHistory.map(\.content), ["recent saved message"])
        XCTAssertEqual(service.transientState, CommandModeService.TransientState())
        XCTAssertEqual(self.store.sessions.first { $0.id == "active" }?.messages.last?.content, "unsaved active answer")

        service.seedTransientState()
        service.createNewChat()
        XCTAssertEqual(service.currentChatID, self.store.currentChatID)
        XCTAssertNotEqual(service.currentChatID, "recent")
        XCTAssertTrue(service.conversationHistory.isEmpty)
        XCTAssertEqual(service.transientState, CommandModeService.TransientState())
        XCTAssertTrue(self.store.sessions.contains { $0.id == "recent" })
    }

    // Turns red if loading the next chat writes to the notch while notch output is off.
    func testChatChangesLeaveTheNotchAloneWhenItsOutputIsOff() throws {
        let service = try self.fixture()
        service.enableNotchOutput = false
        let before = self.notch

        XCTAssertTrue(service.deleteChat(id: "active"))

        XCTAssertEqual(self.notch, before)
    }

    // Turns red if opening saved chats rewrites their messages or dates, or writes anything but the open chat's ID.
    func testBrowsingDoesNotRewriteHistory() throws {
        let service = try self.fixture()
        service.conversationHistory.removeLast()
        let before = self.store.sessions
        XCTAssertNotEqual(service.conversationHistory.first?.id, before.first?.messages.first?.id, "Display message IDs are regenerated on load")

        service.saveCurrentChat()
        XCTAssertEqual(self.defaults.writes, 0)
        for id in ["recent", "older", "active", "recent", "active"] {
            XCTAssertTrue(service.switchToChat(id: id), id)
            XCTAssertEqual(self.store.sessions, before, id)
        }
        XCTAssertEqual(self.defaults.writtenKeys, Array(repeating: "CommandModeCurrentChatID", count: 5))

        let writes = self.defaults.writes
        service.saveCurrentChat()
        XCTAssertEqual(self.defaults.writes, writes)
    }

    // Turns red if a change to a message's role, text, step or tool call is skipped because the message count is the same.
    func testEveryMessageChangeIsSaved() throws {
        typealias Message = CommandModeService.Message
        let tool = Message.ToolCall(id: "tool", command: "pwd", workingDirectory: "/tmp", purpose: "Inspect location")
        let changes: [(String, Message)] = [
            ("role", .init(role: .tool, content: "original", toolCall: tool, stepType: .checking)),
            ("content", .init(role: .assistant, content: "updated", toolCall: tool, stepType: .checking)),
            ("step", .init(role: .assistant, content: "original", toolCall: tool, stepType: .success)),
            ("tool ID", .init(role: .assistant, content: "original", toolCall: .init(id: "other", command: "pwd", workingDirectory: "/tmp", purpose: "Inspect location"), stepType: .checking)),
            ("command", .init(role: .assistant, content: "original", toolCall: .init(id: "tool", command: "ls", workingDirectory: "/tmp", purpose: "Inspect location"), stepType: .checking)),
            ("directory", .init(role: .assistant, content: "original", toolCall: .init(id: "tool", command: "pwd", workingDirectory: "/var", purpose: "Inspect location"), stepType: .checking)),
            ("purpose", .init(role: .assistant, content: "original", toolCall: .init(id: "tool", command: "pwd", workingDirectory: "/tmp", purpose: "Updated purpose"), stepType: .checking)),
            ("removed tool", .init(role: .assistant, content: "original", stepType: .checking)),
        ]
        for (name, replacement) in changes {
            let service = try self.fixture()
            service.conversationHistory = [.init(role: .assistant, content: "original", toolCall: tool, stepType: .checking)]
            service.saveCurrentChat()
            let before = self.store.currentSession
            let writesBefore = self.defaults.writes

            service.conversationHistory = [replacement]
            service.saveCurrentChat()

            let after = self.store.currentSession
            XCTAssertGreaterThan(self.defaults.writes, writesBefore, name)
            XCTAssertNotEqual(after?.searchRevision, before?.searchRevision, name)
            XCTAssertEqual(after?.messages.first?.content, replacement.content, name)
            XCTAssertEqual(after?.messages.first?.toolCall?.command, replacement.toolCall?.command, name)
            let writesAfter = self.defaults.writes
            service.saveCurrentChat()
            XCTAssertEqual(self.defaults.writes, writesAfter, name)
        }

        let service = try self.fixture()
        service.saveCurrentChat()
        let writesBefore = self.defaults.writes
        service.conversationHistory.removeLast()
        service.saveCurrentChat()
        XCTAssertGreaterThan(self.defaults.writes, writesBefore)
        XCTAssertEqual(self.store.currentSession?.messages.count, 1)
    }

    // Turns red if the "Command cancelled." message added by a cancel is lost when switching chats.
    func testACancelMessageIsSavedOnSwitch() throws {
        let service = try self.fixture()
        service.conversationHistory.removeLast()
        service.conversationHistory.append(.init(role: .assistant, content: "Command cancelled.", stepType: .failure))

        XCTAssertTrue(service.switchToChat(id: "recent"))

        let saved = self.store.sessions.first { $0.id == "active" }
        XCTAssertEqual(saved?.messages.last?.content, "Command cancelled.")
        XCTAssertEqual(saved?.messages.last?.stepType, .failure)
        XCTAssertNotNil(saved?.searchRevision)
    }

    // Turns red if a chat saved before archiving existed fails to load, or archive state is lost on save and reload.
    func testArchivedChatsSurviveSaveAndReload() throws {
        let legacy = ChatSession(id: "legacy", title: "Old conversation", messages: [.init(role: .user, content: "Keep my message")])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        object.removeValue(forKey: "isArchived")
        let decoded = try JSONDecoder().decode(ChatSession.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded, legacy)
        XCTAssertFalse(decoded.isArchived)

        let service = try self.fixture()
        XCTAssertTrue(service.archiveChat(id: "older"))
        let expected = self.store.sessions
        XCTAssertEqual(try JSONDecoder().decode([ChatSession].self, from: JSONEncoder().encode(expected)), expected)

        let reloaded = ChatHistoryStore(defaults: self.defaults)
        XCTAssertEqual(reloaded.sessions, expected)
        XCTAssertEqual(reloaded.currentChatID, "active")
        XCTAssertFalse(reloaded.getRecentChats(excludingCurrent: false).contains { $0.isArchived })
    }

    // Turns red if archiving the open chat drops its unsaved answer, keeps its progress, or opens an archived chat.
    func testArchivingTheOpenChatSavesItAndOpensTheNext() throws {
        let service = try self.fixture()

        XCTAssertTrue(service.archiveChat(id: "active"))

        let archived = self.store.sessions.first { $0.id == "active" }
        XCTAssertEqual(archived?.isArchived, true)
        XCTAssertEqual(archived?.messages.last?.content, "unsaved active answer")
        XCTAssertEqual(service.currentChatID, "recent")
        XCTAssertEqual(self.store.currentChatID, "recent")
        XCTAssertEqual(service.transientState, CommandModeService.TransientState())
        XCTAssertEqual(service.conversationHistory.map(\.content), ["recent saved message"])
        if self.notchSyncs { XCTAssertEqual(self.notch, ["recent saved message"]) }

        XCTAssertTrue(service.archiveChat(id: "older"))
        XCTAssertTrue(service.archiveChat(id: "recent"))
        XCTAssertEqual(self.store.sessions.filter(\.isArchived).count, 3)
        XCTAssertEqual(self.store.currentSession?.isArchived, false)
        XCTAssertTrue(service.conversationHistory.isEmpty)
        XCTAssertEqual(service.currentChatID, self.store.currentChatID)
    }

    // Turns red if archiving or restoring another chat changes the open chat, or restore loses messages or dates.
    func testArchivingAndRestoringAnotherChatKeepsTheOpenOne() throws {
        let service = try self.fixture()
        let before = self.snapshot(service)
        let original = self.store.sessions.first { $0.id == "older" }

        XCTAssertTrue(service.archiveChat(id: "older"))
        let archived = self.store.sessions.first { $0.id == "older" }
        XCTAssertEqual(archived?.messages, original?.messages)
        XCTAssertEqual(archived?.updatedAt, original?.updatedAt)
        XCTAssertEqual(self.store.currentSession, before.sessions.first { $0.id == "active" })
        XCTAssertEqual(service.currentChatID, before.currentID)
        XCTAssertEqual(service.conversationHistory, before.conversation)
        XCTAssertEqual(service.transientState, before.transient)
        XCTAssertEqual(self.notch, before.notch)

        XCTAssertTrue(service.restoreChat(id: "older"))
        let restored = self.store.sessions.first { $0.id == "older" }
        XCTAssertEqual(restored?.isArchived, false)
        XCTAssertEqual(restored?.messages, original?.messages)
        XCTAssertEqual(restored?.updatedAt, original?.updatedAt)
        XCTAssertGreaterThan(restored?.searchRevision ?? 0, archived?.searchRevision ?? 0)
        XCTAssertEqual(service.currentChatID, before.currentID)
        XCTAssertEqual(service.conversationHistory, before.conversation)
        XCTAssertEqual(service.transientState, before.transient)
        XCTAssertTrue(service.switchToChat(id: "older"))
    }

    // Turns red if archive or restore runs during a command or approval, or a stale or duplicate row action changes anything.
    func testArchiveAndRestoreRefuseBlockedAndStaleActions() throws {
        for pendingApproval in [false, true] {
            let service = try self.fixture()
            XCTAssertTrue(service.archiveChat(id: "older"))
            if pendingApproval {
                service.pendingCommand = .init(id: "approval", command: "test command", workingDirectory: nil, purpose: nil)
            } else {
                service.isProcessing = true
            }
            let before = self.snapshot(service)
            XCTAssertFalse(service.archiveChat(id: "active"))
            XCTAssertFalse(service.archiveChat(id: "recent"))
            XCTAssertFalse(service.restoreChat(id: "older"))
            XCTAssertEqual(self.snapshot(service), before, "pending approval: \(pendingApproval)")
        }

        let service = try self.fixture()
        let before = self.snapshot(service)
        for id in ["missing", "", "missing"] {
            XCTAssertFalse(service.archiveChat(id: id), id)
            XCTAssertFalse(service.restoreChat(id: id), id)
        }
        XCTAssertFalse(service.restoreChat(id: "active"))
        XCTAssertEqual(self.snapshot(service), before)

        XCTAssertTrue(service.archiveChat(id: "older"))
        let after = self.snapshot(service)
        XCTAssertFalse(service.archiveChat(id: "older"))
        XCTAssertFalse(service.switchToChat(id: "older"))
        XCTAssertEqual(self.snapshot(service), after)

        XCTAssertTrue(service.restoreChat(id: "older"))
        let restored = self.snapshot(service)
        XCTAssertFalse(service.restoreChat(id: "older"))
        XCTAssertEqual(self.snapshot(service), restored)
    }

    // Turns red if a full archive accepts another chat, or trimming old chats removes or rewrites archived ones.
    func testArchivesHaveTheirOwnLimit() throws {
        let archives = (0..<30).map { index in
            ChatSession(id: "archive-\(index)", updatedAt: Date(timeIntervalSince1970: Double(index)), isArchived: true, messages: [.init(role: .user, content: "Archived \(index)")])
        }
        let active = (0..<30).map { index in
            ChatSession(id: "active-\(index)", updatedAt: Date(timeIntervalSince1970: Double(index + 100)), messages: [.init(role: .user, content: "Active \(index)")])
        }
        try self.makeStore(sessions: active + archives, currentChatID: "active-29")
        let service = CommandModeService(chatStore: self.store)
        service.conversationHistory.append(.init(role: .assistant, content: "unsaved at capacity"))
        let before = self.snapshot(service)

        XCTAssertFalse(service.archiveChat(id: "active-29"))
        XCTAssertFalse(service.archiveChat(id: "active-0"))
        XCTAssertEqual(self.snapshot(service), before)

        for _ in 0..<40 {
            service.createNewChat()
        }
        XCTAssertEqual(self.store.sessions.count, 60)
        XCTAssertEqual(self.store.sessions.filter(\.isArchived), archives)

        let currentID = service.currentChatID
        XCTAssertTrue(service.restoreChat(id: "archive-0"))
        XCTAssertEqual(self.store.sessions.filter { !$0.isArchived }.count, 30)
        XCTAssertTrue(self.store.sessions.contains { $0.id == "archive-0" && !$0.isArchived }, "The restored chat is kept even though it is the oldest")
        XCTAssertEqual(service.currentChatID, currentID)
        XCTAssertEqual(self.store.currentChatID, currentID)
        XCTAssertTrue(service.archiveChat(id: "archive-0"))
        XCTAssertEqual(self.store.sessions.filter(\.isArchived).count, ChatHistoryStore.maxArchivedChats)
    }

    // Turns red if deleting the open chat opens an archived chat instead of a new empty one.
    func testDeletingTheOpenChatNeverOpensAnArchive() throws {
        let service = try self.fixture()
        XCTAssertTrue(service.archiveChat(id: "recent"))
        XCTAssertTrue(service.archiveChat(id: "older"))

        service.deleteCurrentChat()

        XCTAssertEqual(self.store.sessions.filter(\.isArchived).count, 2)
        XCTAssertEqual(self.store.currentSession?.isArchived, false)
        XCTAssertTrue(service.conversationHistory.isEmpty)
    }

    // Turns red if launching with only archived chats drops them or opens one, instead of a new empty chat.
    func testLaunchingWithOnlyArchivesOpensAnEmptyChat() throws {
        let archives = [ChatSession(id: "only-archive", isArchived: true, messages: [.init(role: .user, content: "Keep forever within budget")])]

        try self.makeStore(sessions: archives, currentChatID: "only-archive")

        XCTAssertEqual(self.store.sessions.filter(\.isArchived), archives)
        XCTAssertEqual(self.store.sessions.count, 2)
        XCTAssertEqual(self.store.currentSession?.isArchived, false)
        XCTAssertEqual(self.store.currentSession?.messages.isEmpty, true)
        XCTAssertNotEqual(self.store.currentChatID, "only-archive")
    }
}
