import Foundation

/// Very short dictations ("sounds good", "on my way") gain nothing from AI
/// cleanup but would still wait for it, so they paste the rule-cleaned text.
nonisolated enum ShortDictation {
    static let maxWordsWithoutCleanup = 3

    static func skipsCleanup(_ transcript: String) -> Bool {
        var words = 0
        for _ in transcript.split(whereSeparator: { $0.isWhitespace }) {
            words += 1
            if words > self.maxWordsWithoutCleanup { return false }
        }
        return words > 0
    }
}
