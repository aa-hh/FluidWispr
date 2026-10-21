@testable import FluidVoice_Debug
import Foundation
import XCTest

// The real chat and file transcription stores, each on its own throwaway UserDefaults suite,
// so the installed app's history is never touched.
@MainActor
final class HistoryDecodeRecoveryTests: XCTestCase {
    private static let chatKey = "CommandModeChatSessions"
    private static let fileKey = "FileTranscriptionHistoryEntries"
    private var suites: [String] = []

    override func tearDown() {
        for suite in self.suites {
            UserDefaults().removePersistentDomain(forName: suite)
        }
        self.suites = []
        super.tearDown()
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "HistoryDecodeRecoveryTests.\(UUID().uuidString)"
        self.suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private let files = (0..<2).map {
        FileTranscriptionEntry(fileName: "meeting\($0).wav", duration: 60, processingTime: 5, confidence: 0.9, text: "Transcript \($0)")
    }

    // Turns red if one unreadable file transcript wipes the readable ones, or the next save
    // drops them.
    func testFileHistorySurvivesOneUnreadableEntry() throws {
        let files = self.files
        var unreadableFile = try Self.object(files[0])
        unreadableFile["id"] = UUID().uuidString
        unreadableFile["confidence"] = NSNull()
        let fileDefaults = try self.makeDefaults()
        fileDefaults.set(try Self.array(files, inserting: unreadableFile), forKey: Self.fileKey)
        let fileStore = FileTranscriptionHistoryStore(defaults: fileDefaults)
        XCTAssertEqual(fileStore.entries, files, "Readable file transcripts must survive one unreadable entry")
        fileStore.addEntry(TranscriptionResult(
            text: "New transcript",
            confidence: 0.8,
            duration: 10,
            processingTime: 1,
            fileName: "new.wav"
        ))
        let reloadedFiles = FileTranscriptionHistoryStore(defaults: fileDefaults).entries
        XCTAssertEqual(reloadedFiles.count, 3)
        XCTAssertEqual(Array(reloadedFiles.dropFirst()), files, "The next save must keep every readable transcript, newest first")
    }

    // Turns red if other element shapes or an out-of-range number make the whole history
    // unreadable instead of being skipped one element at a time.
    func testFileHistorySkipsAnyMixOfUnreadableElements() throws {
        let files = self.files
        // Literal JSON, so no encoder normalizes the inputs. A complete entry that only
        // becomes unreadable because its duration overflows Double.
        let overflowSource = try Self.json(FileTranscriptionEntry(fileName: "overflow.wav", duration: 60, processingTime: 5, confidence: 0.9, text: "Overflow"))
        let overflowing = overflowSource.replacingOccurrences(of: #""duration":60"#, with: #""duration":1e400"#)
        XCTAssertNotEqual(overflowing, overflowSource, "The overflow fixture must replace the duration")
        XCTAssertNotNil(try? JSONDecoder().decode(FileTranscriptionEntry.self, from: Data(overflowSource.utf8)), "The overflow fixture is readable before the change")
        let literalDefaults = try self.makeDefaults()
        literalDefaults.set(Data(#"""
        [\#(try Self.json(files[0])),"junk",null,\#(overflowing),\#(try Self.json(files[1], extra: #""futureField":1e400"#))]
        """#.utf8), forKey: Self.fileKey)
        XCTAssertEqual(FileTranscriptionHistoryStore(defaults: literalDefaults).entries, files, "Readable transcripts survive any mix of unreadable elements")

        let garbageDefaults = try self.makeDefaults()
        garbageDefaults.set(Data("not json".utf8), forKey: Self.fileKey)
        XCTAssertTrue(FileTranscriptionHistoryStore(defaults: garbageDefaults).entries.isEmpty, "Unparseable history loads empty")
    }

    // Turns red if loading readable file history rewrites the stored bytes.
    func testReadableFileHistoryLoadsUnchanged() throws {
        let files = self.files
        let cleanFileDefaults = try self.makeDefaults()
        let cleanFileBytes = try JSONEncoder().encode(files)
        cleanFileDefaults.set(cleanFileBytes, forKey: Self.fileKey)
        XCTAssertEqual(FileTranscriptionHistoryStore(defaults: cleanFileDefaults).entries, files, "Readable history loads unchanged")
        XCTAssertEqual(cleanFileDefaults.data(forKey: Self.fileKey), cleanFileBytes, "Loading readable history must not rewrite it")
    }

    // Turns red if one unreadable Command Mode chat makes the launch save overwrite every
    // chat with a single new one.
    func testChatHistorySurvivesOneUnreadableChat() throws {
        let chats = (0..<2).map {
            ChatSession(title: "Chat \($0)", messages: [ChatMessage(role: .user, content: "Hello \($0)")])
        }
        var unreadableChat = try Self.object(chats[0])
        let unreadableChatID = UUID().uuidString
        unreadableChat["id"] = unreadableChatID
        var messages = try XCTUnwrap(unreadableChat["messages"] as? [[String: Any]], "Encoded chat must carry messages")
        messages[0]["stepType"] = "stepFromANewerVersion"
        unreadableChat["messages"] = messages
        let chatDefaults = try self.makeDefaults()
        chatDefaults.set(try Self.array(chats, inserting: unreadableChat), forKey: Self.chatKey)
        chatDefaults.set(unreadableChatID, forKey: "CommandModeCurrentChatID")
        let chatStore = ChatHistoryStore(defaults: chatDefaults)
        XCTAssertEqual(chatStore.sessions.map(\.id), chats.map(\.id), "Readable chats must survive one unreadable chat")
        XCTAssertTrue(chats.contains { $0.id == chatStore.currentChatID }, "A missing current chat falls back to a readable one")
        let savedChats = try JSONDecoder().decode([ChatSession].self, from: chatDefaults.data(forKey: Self.chatKey) ?? Data())
        XCTAssertEqual(savedChats.map(\.id), chats.map(\.id), "The launch save must keep every readable chat")
    }

    // Turns red if loading readable chats rewrites them or loses the current chat.
    func testReadableChatHistoryLoadsUnchanged() throws {
        let chats = (0..<2).map {
            ChatSession(title: "Chat \($0)", messages: [ChatMessage(role: .user, content: "Hello \($0)")])
        }
        let cleanChatDefaults = try self.makeDefaults()
        let cleanChatBytes = try JSONEncoder().encode(chats)
        cleanChatDefaults.set(cleanChatBytes, forKey: Self.chatKey)
        cleanChatDefaults.set(chats[1].id, forKey: "CommandModeCurrentChatID")
        let cleanChatStore = ChatHistoryStore(defaults: cleanChatDefaults)
        XCTAssertEqual(cleanChatStore.sessions, chats, "Readable chats load unchanged")
        XCTAssertEqual(cleanChatStore.currentChatID, chats[1].id)
        XCTAssertEqual(cleanChatDefaults.data(forKey: Self.chatKey), cleanChatBytes, "Loading readable chats must not rewrite them")
    }

    private static func object(_ value: some Encodable) throws -> [String: Any] {
        try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any],
            "Encoded history entry must be a JSON object"
        )
    }

    private static func json(_ value: some Encodable, extra: String? = nil) throws -> String {
        let text = try XCTUnwrap(String(bytes: try JSONEncoder().encode(value), encoding: .utf8), "Encoded history entry must be UTF-8")
        guard let extra else { return text }
        return String(text.dropLast()) + "," + extra + "}"
    }

    private static func array(_ values: [some Encodable], inserting unreadable: [String: Any]) throws -> Data {
        var array = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(values)) as? [Any],
            "Encoded history must be a JSON array"
        )
        array.insert(unreadable, at: 1)
        return try JSONSerialization.data(withJSONObject: array)
    }
}
