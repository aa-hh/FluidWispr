import Combine
import Foundation

/// A text field inside the app that dictation can practise into. While it is active, dictation
/// is kept out of other apps and its final text lands in `text`.
@MainActor
final class DictationPracticeField: ObservableObject {
    static let shared = DictationPracticeField()

    @Published var isActive = false
    @Published var text = ""

    private init() {}
}
