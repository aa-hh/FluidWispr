@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class CommandPresentationTests: XCTestCase {
    // Turns red if a session shows another session's unsent text, or clearing one draft clears another.
    func testDraftsBelongToTheirSessions() {
        var drafts = CommandSessionDrafts()
        drafts.set("Explain this file", for: "first")
        drafts.set("Check my storage", for: "second")
        XCTAssertTrue(drafts.text(for: "first") == "Explain this file", "Returning to the first session restores its unsent text")
        XCTAssertTrue(drafts.text(for: "second") == "Check my storage", "The second session keeps its own unsent text")
        XCTAssertTrue(drafts.text(for: "third").isEmpty, "A newly selected session starts without another session's text")
        drafts.set("", for: "first")
        XCTAssertTrue(drafts.text(for: "first").isEmpty, "Submitting or clearing removes only that session's draft")
        XCTAssertTrue(drafts.text(for: "second") == "Check my storage", "Clearing another session preserves this draft")
        drafts.set("line one\n  line two  ", for: "second")
        XCTAssertTrue(drafts.text(for: "second") == "line one\n  line two  ", "Draft storage preserves formatting and trailing whitespace for editing")
        drafts.set("   ", for: "first")
        XCTAssertTrue(drafts.text(for: "first") == "   ", "Draft storage does not trim or submit whitespace on its own")
    }

    // Turns red if text typed with no session selected lands in a session, or a deleted session's draft comes back.
    func testNilAndRemovedSessionsHaveNoDraft() {
        var drafts = CommandSessionDrafts()
        drafts.set("orphan text", for: nil)
        XCTAssertTrue(drafts.text(for: nil).isEmpty, "Without a selected session, text is not assigned to any other session")
        drafts.set("keep", for: "kept")
        drafts.set("delete", for: "removed")
        drafts.retain(sessionIDs: ["kept", "new", "kept"])
        XCTAssertTrue(drafts.text(for: "kept") == "keep", "Retaining sessions preserves the existing live draft")
        XCTAssertTrue(drafts.text(for: "removed").isEmpty, "Deleted session IDs no longer retain unsent text")
        XCTAssertTrue(drafts.text(for: "new").isEmpty, "Retaining a new ID does not create or inherit a draft")
        drafts.retain(sessionIDs: ["kept", "new"])
        XCTAssertTrue(drafts.text(for: "kept") == "keep", "Repeated retention is stable")
        drafts.retain(sessionIDs: [])
        XCTAssertTrue(drafts.text(for: "kept").isEmpty && drafts.text(for: "removed").isEmpty, "An empty session list drops all drafts")
        drafts.retain(sessionIDs: ["removed"])
        XCTAssertTrue(drafts.text(for: "removed").isEmpty, "Reintroducing a removed ID does not resurrect deleted text")
    }

    // Turns red if pruning keeps drafts of deleted sessions or drops a live session's draft.
    func testRapidSessionTurnoverKeepsOnlyLiveDrafts() {
        var drafts = CommandSessionDrafts()
        var liveIDs: [String] = []
        for index in 0..<300 {
            let id = "session-\(index)"
            drafts.set("draft-\(index)", for: id)
            liveIDs.append(id)
            if liveIDs.count > 30 {
                let removedID = liveIDs.removeFirst()
                drafts.retain(sessionIDs: liveIDs)
                XCTAssertTrue(drafts.text(for: removedID).isEmpty, "Rapid create/delete cycles remove every discarded draft")
            } else {
                drafts.retain(sessionIDs: liveIDs)
            }
            XCTAssertTrue(drafts.text(for: id) == "draft-\(index)", "Pruning preserves the newly created session's draft")
        }
        for index in 0..<270 {
            XCTAssertTrue(drafts.text(for: "session-\(index)").isEmpty, "Discarded IDs stay absent after later retention passes")
        }
        for index in 270..<300 {
            XCTAssertTrue(drafts.text(for: "session-\(index)") == "draft-\(index)", "The bounded live set preserves each session's distinct text")
        }
        drafts.retain(sessionIDs: [])
        for id in liveIDs {
            XCTAssertTrue(drafts.text(for: id).isEmpty, "Deleting the remaining sessions clears all surviving drafts")
        }
    }

    // Turns red if copies of the drafts share storage, or a new workspace loads drafts from somewhere shared.
    func testDraftsAreIndependentValues() {
        var firstWorkspace = CommandSessionDrafts()
        firstWorkspace.set("original", for: "same-session")
        var secondWorkspace = firstWorkspace
        secondWorkspace.set("other edit", for: "same-session")
        XCTAssertTrue(firstWorkspace.text(for: "same-session") == "original", "Editing a copied workspace cannot mutate the first workspace's draft")
        XCTAssertTrue(secondWorkspace.text(for: "same-session") == "other edit", "The copied workspace owns its new draft value")
        secondWorkspace.retain(sessionIDs: [])
        XCTAssertTrue(firstWorkspace.text(for: "same-session") == "original", "Pruning another value cannot mutate live drafts")
        let freshWorkspace = CommandSessionDrafts()
        XCTAssertTrue(freshWorkspace.text(for: "same-session").isEmpty, "A fresh workspace does not load drafts from shared persistence")
    }

    // Turns red if the history sidebar docks below its minimum width, ignores the hide preference, or leaves no room for the conversation.
    func testHistoryDocksByWidthAndPreference() {
        let threshold = CommandWorkspaceLayout.dockedHistoryMinimumWidth
        XCTAssertTrue(!CommandWorkspaceLayout.showsDockedHistory(width: 0, preferred: true), "A zero-width workspace does not reserve sidebar space")
        XCTAssertTrue(!CommandWorkspaceLayout.showsDockedHistory(width: 640, preferred: true), "A narrow workspace leaves history undocked even with the default visible preference")
        XCTAssertTrue(!CommandWorkspaceLayout.showsDockedHistory(width: threshold - 0.5, preferred: true), "History stays undocked immediately below the width boundary")
        XCTAssertTrue(CommandWorkspaceLayout.showsDockedHistory(width: threshold, preferred: true), "History docks at the exact supported width")
        XCTAssertTrue(CommandWorkspaceLayout.showsDockedHistory(width: threshold + 0.5, preferred: true), "History docks immediately above the width boundary")
        XCTAssertTrue(CommandWorkspaceLayout.showsDockedHistory(width: 1440, preferred: true), "A wide workspace shows history with the default visible preference")
        for width: CGFloat in [0, 640, threshold, 1440] {
            XCTAssertTrue(!CommandWorkspaceLayout.showsDockedHistory(width: width, preferred: false), "Explicitly hiding history is honored at every width")
        }
        XCTAssertTrue(CommandWorkspaceLayout.showsDockedHistory(width: threshold, preferred: true), "A previous hidden-width query does not change future visibility")
        XCTAssertTrue(CommandWorkspaceLayout.sidebarWidth > 0 && CommandWorkspaceLayout.sidebarWidth < threshold, "The docked sidebar leaves positive width for the conversation")
        XCTAssertTrue(CommandWorkspaceLayout.conversationMaximumWidth > 0, "The conversation has a finite readable width limit")
    }

    // Turns red if the reply parser merges or misclassifies blocks, drops inline styles, breaks on
    // CRLF or unfinished code fences, splits escaped table pipes, or hides rows past the table limit.
    func testMarkdownParserBlocks() {
        let parsed = CommandMarkdownParser.parse("# Heading\n\nA **bold** sentence with `code`.\n\n- First\n  - Nested\n2. Second\n\n> Quote\n> continued\n\n---")
        XCTAssertEqual(parsed.count, 7, "Headings, paragraphs, lists, quotes and rules must stay separate blocks")
        guard parsed.count == 7 else { return }
        guard case let .heading(heading, level) = parsed[0].content else { return XCTFail("Missing heading") }
        XCTAssertTrue(level == 1 && String(heading.characters) == "Heading")
        guard case let .paragraph(paragraph) = parsed[1].content else { return XCTFail("Missing paragraph") }
        XCTAssertTrue(String(paragraph.characters) == "A bold sentence with code.")
        XCTAssertTrue(paragraph.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(paragraph.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
        guard case let .listItem(_, marker, depth) = parsed[3].content else { return XCTFail("Missing nested item") }
        XCTAssertTrue(marker == "•" && depth == 1)
        guard case let .listItem(_, orderedMarker, _) = parsed[4].content else { return XCTFail("Missing ordered item") }
        XCTAssertTrue(orderedMarker == "2.")
        guard case let .quote(quote) = parsed[5].content else { return XCTFail("Missing quote") }
        XCTAssertTrue(String(quote.characters) == "Quote\ncontinued")

        let fenced = CommandMarkdownParser.parse("```swift\nlet value = 1\n# literal heading\n```\n\nAfter")
        XCTAssertEqual(fenced.count, 2)
        guard case let .code(code, language) = fenced.first?.content else { return XCTFail("Missing fenced code") }
        XCTAssertTrue(code == "let value = 1\n# literal heading" && language == "swift")
        let windowsFence = CommandMarkdownParser.parse("```text\r\none\r\ntwo\r\n```")
        guard case let .code(windowsCode, _) = windowsFence.first?.content else { return XCTFail("Missing CRLF code") }
        XCTAssertTrue(windowsCode == "one\ntwo", "CRLF must not introduce empty code lines")
        let unfinished = CommandMarkdownParser.parse("~~~json\n{\"streaming\": true")
        guard case let .code(partial, _) = unfinished.first?.content else { return XCTFail("Partial streaming fence disappeared") }
        XCTAssertTrue(partial == "{\"streaming\": true")

        let tables = CommandMarkdownParser.parse("| Name | Value |\n| :--- | ---: |\n| `a|b` | yes |\n| escaped\\|pipe | no |")
        guard case let .table(headers, rows) = tables.first?.content else { return XCTFail("Missing table") }
        XCTAssertEqual(headers.count, 2)
        XCTAssertEqual(rows.count, 2)
        guard rows.count == 2 else { return }
        XCTAssertTrue(String(rows[0][0].characters) == "a|b")
        XCTAssertTrue(String(rows[1][0].characters) == "escaped|pipe")
        let nestedCode = CommandMarkdownParser.parse("| Name | Value |\n| --- | --- |\n| ``a|`b`` | yes |")
        guard case let .table(_, codeRows) = nestedCode.first?.content else { return XCTFail("Missing code span table") }
        XCTAssertEqual(codeRows.first.map { String($0[0].characters) }, "a|`b")
        XCTAssertEqual(codeRows.count, 1)
        let longTable = "| a | b |\n| --- | --- |\n" + Array(repeating: "| x | y |", count: 105).joined(separator: "\n")
        let bounded = CommandMarkdownParser.parse(longTable)
        guard case let .table(_, boundedRows) = bounded.first?.content else { return XCTFail("Missing bounded table") }
        XCTAssertTrue(boundedRows.count == 100 && bounded.count > 1, "Overflow rows must remain visible below the bounded table")
        XCTAssertTrue(CommandMarkdownParser.parse("").isEmpty)
        let literal = CommandMarkdownParser.parse("#not-heading\n2.not-list\n日本語 👨‍👩‍👧‍👦")
        guard case let .paragraph(value) = literal.first?.content else { return XCTFail("Literal text misclassified") }
        XCTAssertTrue(String(value.characters) == "#not-heading\n2.not-list\n日本語 👨‍👩‍👧‍👦")
    }

    // Turns red if tool results lose their success, output, error or timing fields, or unknown and
    // plain-text results stop being shown as they are.
    func testToolOutputParsing() {
        let terminal = CommandToolOutput.parse("{\"success\":true,\"output\":\"hello\",\"executionTimeMs\":32}")
        XCTAssertTrue(terminal.success == true && terminal.output == "hello" && terminal.executionTime == 32)
        let error = CommandToolOutput.parse("{\"success\":false,\"output\":\"\",\"error\":\"Permission denied\"}")
        XCTAssertTrue(error.success == false && error.error == "Permission denied")
        let unknown = "{\"new_tool_result\": [1, 2, 3]}"
        XCTAssertTrue(CommandToolOutput.parse(unknown).output == unknown, "Unknown result formats must remain inspectable")
        XCTAssertTrue(CommandToolOutput.parse("plain legacy output").output == "plain legacy output")
    }
}
