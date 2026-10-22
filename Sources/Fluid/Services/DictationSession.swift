import AppKit
import Combine
import Foundation

/// The state of the dictation in progress: which mode is recording, which lifecycle owns the
/// overlay, where the text goes, and the spoken-send countdown. AppServices holds the one
/// instance, so rebuilding the main window or opening a second one does not reset or fork it.
@MainActor
final class DictationSession {
    enum RecordingMode: String {
        case none
        case dictate
        case promptMode
        case edit
        case command
    }

    /// Where a stopped dictation goes: pasted normally, kept in the onboarding practice field, or
    /// saved to History only (Escape during processing).
    enum OutputRoute: String {
        case normal
        case onboardingSandbox
        case historyOnly

        var savesHistory: Bool { self != .onboardingSandbox }
        var deliversText: Bool { self == .normal }
        var publishesEditorResult: Bool { self != .historyOnly }
    }

    var activeRecordingMode: RecordingMode = .none
    var activeDictationShortcutSlot: SettingsStore.DictationShortcutSlot?
    var isRecordingForRewrite = false
    var isRecordingForCommand = false
    /// System prompt text to use when in prompt mode.
    var promptModeOverrideText: String?
    var pendingAIReprocessText: String?
    /// Mirrors the main window's Fluid Intelligence demo sheet. While it is open, a new recording
    /// starts only for a prompt test.
    var isFluidIntelligenceDemoShowing = false

    /// The one global shortcut listener. Created by `initializeHotkeyManagerIfNeeded`.
    var hotkeyManager: GlobalHotkeyManager?
    /// Called with the event tap's health after each check, for the shortcut settings screen.
    var onHotkeyHealthChecked: ((Bool) -> Void)?
    /// The main window sets these while it is recording a new shortcut in Settings.
    var isShortcutCaptureActive: () -> Bool = { false }
    var shortcutCaptureHandler: (NSEvent) -> NSEvent? = { $0 }
    /// Lets the main window take part in Escape, such as leaving the Edit page. Returns whether it did.
    var cancelShortcutWindowHandler: () -> Bool = { false }
    /// The window whose hooks are set above. With two windows open, closing the older one must keep the newer one's.
    var windowHooksOwner: UUID?

    /// Puts the window hooks back to their defaults, unless another window has taken them since.
    func releaseWindowHooks(owner: UUID) {
        guard self.windowHooksOwner == owner else { return }
        self.windowHooksOwner = nil
        self.isShortcutCaptureActive = { false }
        self.shortcutCaptureHandler = { $0 }
        self.cancelShortcutWindowHandler = { false }
        self.onHotkeyHealthChecked = nil
    }

    var overlayLifecycleID: UInt64 = 0
    var processingDictationLifecycleID: UInt64?
    var pendingVoiceCommandLifecycleID: UInt64?
    var cancelledOutputLifecycleID: UInt64?
    var isSavingCancelledRecording = false
    var prewarmDictationTask: Task<Void, Never>?

    var recordingAppInfo: (name: String, bundleId: String, windowTitle: String)?
    var recordingPrecedingText = ""
    var recordingFocusTarget: TypingService.CapturedFocusTarget?

    var spokenSendAutoStopTask: Task<Void, Never>?
    var spokenSendAutoStopTriggered = false
    var spokenSendArming = SpokenSendArmingState()
    var spokenSendCountdownStartedAt: TimeInterval?
    var spokenSendLastVoiceActivityAt: TimeInterval = 0
    var spokenSendVoiceActivityCancellable: AnyCancellable?

    /// Command Mode and Edit Mode belong to the session, not to a window, so a second window
    /// shows the same chat and edit in progress. Created on first use, as the views did.
    lazy var commandMode = CommandModeService()
    lazy var rewriteMode = RewriteModeService()

    /// The menu bar owner, set when the main window appears. The session never runs a
    /// dictation before that, because the hotkeys are installed there too.
    weak var menuBarManager: MenuBarManager?

    private let asrOverride: ASRService?

    /// Tests pass their own speech service; the app uses the shared one.
    init(asr: ASRService? = nil) {
        self.asrOverride = asr
    }

    var asr: ASRService { self.asrOverride ?? AppServices.shared.asr }
}
