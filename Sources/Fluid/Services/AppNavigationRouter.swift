import Foundation

enum AppNavigationDestination {
    case aiEnhancements
    case history
    case dictationShortcuts
    case meetingTranscription
    case customDictionary
}

@MainActor
final class AppNavigationRouter {
    static let shared = AppNavigationRouter()

    private var pendingDestination: AppNavigationDestination?

    private init() {}

    func request(_ destination: AppNavigationDestination) {
        self.pendingDestination = destination
        NotificationCenter.default.post(name: .appNavigationRequested, object: nil)
    }

    func consumePendingDestination() -> AppNavigationDestination? {
        let destination = self.pendingDestination
        self.pendingDestination = nil
        return destination
    }
}

extension Notification.Name {
    static let appNavigationRequested = Notification.Name("AppNavigationRequested")
    static let releaseHighlightsRequested = Notification.Name("ReleaseHighlightsRequested")
    static let replayOnboardingRequested = Notification.Name("ReplayOnboardingRequested")
    /// ⌘F outside Settings: the page in front focuses its own search field.
    static let pageSearchFocusRequested = Notification.Name("pageSearchFocusRequested")
    static let clearHistoryRequested = Notification.Name("ClearHistoryRequested")
    static let dictationPromptShortcutsChanged = Notification.Name("DictationPromptShortcutsChanged")
    static let newPromptShortcutRecorded = Notification.Name("NewPromptShortcutRecorded")
}
