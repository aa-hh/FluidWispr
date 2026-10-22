@testable import FluidVoice_Debug
import XCTest

final class CleanupMeaningGuardTests: XCTestCase {
    private func assertKept(_ transcript: String, _ cleaned: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(CleanupMeaningGuard.check(transcript: transcript, cleaned: cleaned), "\(transcript) -> \(cleaned)", file: file, line: line)
    }

    // Turns red if a cleanup that drops or adds "not", "never" or an n't word gets pasted.
    func testDroppedOrAddedNegationFallsBack() {
        XCTAssertEqual(
            CleanupMeaningGuard.check(transcript: "um so I do not want to go there", cleaned: "I want to go there."),
            .negations(transcript: 1, cleaned: 0)
        )
        XCTAssertNotNil(CleanupMeaningGuard.check(transcript: "I don't think we should ship it", cleaned: "I think we should ship it."))
        XCTAssertNotNil(CleanupMeaningGuard.check(transcript: "I never said that", cleaned: "I said that."))
        XCTAssertNotNil(CleanupMeaningGuard.check(transcript: "we will meet you there", cleaned: "We won't meet you there."))
    }

    // Turns red if rewording a negation, a spoken correction or a stuttered repeat stops passing.
    func testNegationRewordsCorrectionsAndRepeatsPass() {
        self.assertKept("I do not know", "I don\u{2019}t know.")
        self.assertKept("I have nothing", "I have nothing.")
        self.assertKept("i can't actually i can make it", "I can make it.")
        self.assertKept("I don't, I don't think so", "I don't think so.")
        self.assertKept("I don't, I don't think so", "I don't, I don't think so.")
    }

    // Turns red if spoken numbers stop reading the same as the digits the cleanup writes for them.
    func testSpokenNumbersMatchTheirDigits() {
        self.assertKept("meet me at five thirty", "Meet me at 5:30.")
        self.assertKept("it costs twelve fifty", "It costs $12.50.")
        self.assertKept("born in nineteen ninety nine", "Born in 1999.")
        self.assertKept("two thousand twenty four", "2024")
        self.assertKept("one hundred and five people", "105 people")
        self.assertKept("that's one thousand two hundred", "That's 1,200.")
        self.assertKept("five million users", "5 million users")
        self.assertKept("twenty first of october", "21st of October")
        self.assertKept("two three four", "2, 3, 4")
        self.assertKept("the one I like", "The one I like.")
        self.assertKept("um the the meeting is at ten", "The meeting is at 10.")
    }

    // Turns red if a changed, added or dropped number gets pasted, or a correction that drops one stops passing.
    func testChangedNumberFallsBackUnlessCorrected() {
        XCTAssertEqual(
            CleanupMeaningGuard.check(transcript: "send it to room twelve", cleaned: "Send it to room 21."),
            .numbers(transcriptDigits: 2, cleanedDigits: 2)
        )
        XCTAssertNotNil(CleanupMeaningGuard.check(transcript: "fifteen dollars", cleaned: "$50"))
        XCTAssertNotNil(CleanupMeaningGuard.check(transcript: "meet at five", cleaned: "Meet at 5 or 6."))
        XCTAssertNotNil(CleanupMeaningGuard.check(transcript: "the code is four four two", cleaned: "The code is 42."))
        self.assertKept("meet at five actually six", "Meet at 6.")
    }
}
