@testable import FluidVoice_Debug
import Foundation
import XCTest

final class PasteRawReplacementTests: XCTestCase {
    // Turns red if the last paste stops being found at the cursor, or the range starts counting characters instead of UTF-16 units or takes in the space after it.
    func testFindsTheLastPasteJustBeforeTheCursor() {
        XCTAssertEqual(
            PasteRawReplacement.rangeOfDelivery(in: "Notes: I'll be there at 5.", delivered: "I'll be there at 5."),
            NSRange(location: 7, length: 19)
        )
        XCTAssertEqual(
            PasteRawReplacement.rangeOfDelivery(in: "Hi 👋 See you soon. \n", delivered: " See you soon.\n"),
            NSRange(location: 6, length: 13)
        )
        XCTAssertEqual(PasteRawReplacement.rangeOfDelivery(in: "Done.", delivered: "Done."), NSRange(location: 0, length: 5))
    }

    // Turns red if text typed after the paste, a different paste, or an empty one still gets selected and replaced.
    func testNothingIsSelectedWhenTheCursorMovedOn() {
        XCTAssertNil(PasteRawReplacement.rangeOfDelivery(in: "See you soon. Bring snacks", delivered: "See you soon."))
        XCTAssertNil(PasteRawReplacement.rangeOfDelivery(in: "See you later.", delivered: "See you soon."))
        XCTAssertNil(PasteRawReplacement.rangeOfDelivery(in: "soon.", delivered: "See you soon."))
        XCTAssertNil(PasteRawReplacement.rangeOfDelivery(in: "Anything", delivered: "  \n"))
    }
}
