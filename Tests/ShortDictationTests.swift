import Foundation

@main
enum ShortDictationTests {
    static func main() {
        precondition(ShortDictation.skipsCleanup("Sounds good."))
        precondition(ShortDictation.skipsCleanup("  on my\nway  "))
        precondition(!ShortDictation.skipsCleanup("see you there tomorrow"))
        // Nothing to paste is not a short dictation; the caller handles it.
        precondition(!ShortDictation.skipsCleanup("   "))
        precondition(!ShortDictation.skipsCleanup(""))
    }
}
