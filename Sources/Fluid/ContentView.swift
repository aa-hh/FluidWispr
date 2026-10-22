//
//  ContentView.swift
//  fluid
//
//  Created by Barathwaj Anandan on 7/30/25.
//

import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreGraphics
import Security
import SwiftUI

// MARK: - AI Processing Errors

nonisolated enum AIProcessingError: LocalizedError {
    case noVerifiedProvider
    case missingAPIKey(provider: String)
    case missingModel(provider: String)
    case emptyResponse
    case dictationExceedsAIContextWindow

    var errorDescription: String? {
        switch self {
        case .noVerifiedProvider:
            return "No verified AI provider selected"
        case let .missingAPIKey(provider):
            return "API key not set for \(provider)"
        case let .missingModel(provider):
            return "No model selected for \(provider)"
        case .emptyResponse:
            return "AI returned an empty response"
        case .dictationExceedsAIContextWindow:
            return "Dictation exceeded the AI context window"
        }
    }

    /// Configuration errors the user can fix in AI Providers.
    var isConfigurationError: Bool {
        switch self {
        case .noVerifiedProvider, .missingAPIKey, .missingModel:
            return true
        case .emptyResponse, .dictationExceedsAIContextWindow:
            return false
        }
    }
}

nonisolated enum DictationAIFailurePresentationPolicy {
    static func shouldPresent(shouldPersistOutputs: Bool, fallbackReason: String?) -> Bool {
        shouldPersistOutputs && fallbackReason != nil
    }

    static func notificationMessage(for error: Error) -> String {
        if let aiError = error as? AIProcessingError, aiError.isConfigurationError {
            return "\(aiError.localizedDescription). Open AI Providers to configure a provider."
        }
        return error.localizedDescription
    }
}

nonisolated enum DictationStreamingFallbackPolicy {
    /// True when the provider answered with an error status or an unusable reply, so a plain
    /// request is tried once. Errors that are not AI request errors also retry, as they always have.
    static func shouldRetryWithoutStreaming(after error: Error) -> Bool {
        switch LLMErrorKind(error) {
        case .authFailed, .rateLimited, .providerError, .badResponse, .other:
            return true
        case .cancelled, .unreachable, .timedOut, .badRequest:
            return false
        }
    }
}

final nonisolated class DictationAIStreamPreviewBuffer: @unchecked Sendable {
    typealias Publisher = @MainActor @Sendable (String) -> Void

    private let lock = NSLock()
    private let minimumUpdateInterval: TimeInterval
    private let publisher: Publisher
    private var bufferedText = ""
    private var lastPublishedText = ""
    private var nextEligibleUIUpdate: TimeInterval
    private var isUIUpdateScheduled = false

    init(
        minimumUpdateInterval: TimeInterval = 0.033,
        initialUpdateDelay: TimeInterval = 0.5,
        publisher: @escaping Publisher = { text in
            NotchOverlayManager.shared.updateTranscriptionText(text)
        }
    ) {
        self.minimumUpdateInterval = minimumUpdateInterval
        self.nextEligibleUIUpdate = ProcessInfo.processInfo.systemUptime + initialUpdateDelay
        self.publisher = publisher
    }

    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        let shouldSchedule = self.lock.withLock {
            self.bufferedText += chunk
            guard !self.isUIUpdateScheduled,
                  ProcessInfo.processInfo.systemUptime >= self.nextEligibleUIUpdate
            else {
                return false
            }
            self.isUIUpdateScheduled = true
            return true
        }
        guard shouldSchedule else { return }

        Task { @MainActor [weak self] in
            self?.publishScheduledUpdate()
        }
    }

    @MainActor
    func flush() {
        guard let text = self.takeTextForPublishing(requiresScheduledUpdate: false) else { return }
        self.publisher(text)
    }

    @MainActor
    private func publishScheduledUpdate() {
        guard let text = self.takeTextForPublishing(requiresScheduledUpdate: true) else { return }
        self.publisher(text)
    }

    private func takeTextForPublishing(requiresScheduledUpdate: Bool) -> String? {
        self.lock.withLock {
            if requiresScheduledUpdate, !self.isUIUpdateScheduled {
                return nil
            }
            self.isUIUpdateScheduled = false
            self.nextEligibleUIUpdate = ProcessInfo.processInfo.systemUptime + self.minimumUpdateInterval
            guard self.bufferedText != self.lastPublishedText else { return nil }
            self.lastPublishedText = self.bufferedText
            return self.bufferedText
        }
    }
}

enum PrimaryDictationShortcutEdit: Hashable {
    case add
    case replace(Int)

    var replacementIndex: Int? {
        if case let .replace(index) = self { return index }
        return nil
    }
}

enum ShortcutRecordingTarget: Hashable {
    case primaryDictation(PrimaryDictationShortcutEdit)
    case secondaryDictation
    case command
    case edit
    case cancel
    case pasteLast
    case dictationPrompt(String)
    case newPrompt

    var title: String {
        switch self {
        case .primaryDictation:
            return "Primary Dictation Shortcut"
        case .secondaryDictation:
            return "Secondary Dictation Shortcut"
        case .command:
            return "Command Mode"
        case .edit:
            return "Edit Mode"
        case .cancel:
            return "Cancel Recording"
        case .pasteLast:
            return "Paste Last Transcription"
        case .dictationPrompt:
            return "Prompt Shortcut"
        case .newPrompt:
            return "New Prompt Shortcut"
        }
    }

    var enablesFeatureOnAssignment: Bool {
        switch self {
        case .secondaryDictation, .command, .edit, .pasteLast:
            return true
        case .primaryDictation, .cancel, .dictationPrompt, .newPrompt:
            return false
        }
    }

    var promptConfigurationKey: String? {
        if case let .dictationPrompt(key) = self { return key }
        return nil
    }

    var allowsMouseShortcut: Bool {
        switch self {
        case .primaryDictation, .pasteLast:
            return true
        case .secondaryDictation, .command, .edit, .cancel, .dictationPrompt, .newPrompt:
            return false
        }
    }

    var isPrimaryDictation: Bool {
        if case .primaryDictation = self { return true }
        return false
    }

    var primaryDictationReplacementIndex: Int? {
        if case let .primaryDictation(edit) = self {
            return edit.replacementIndex
        }
        return nil
    }
}

// MARK: - Minimal FluidAudio ASR Service (finalized text, macOS)

// MARK: - Saved Provider Model

// Removed deprecated inline service and model

// NOTE: Streaming and AI response parsing is now handled by LLMClient

struct ContentView: View {
    private typealias ActiveRecordingMode = DictationSession.RecordingMode

    typealias DictationOutputRoute = DictationSession.OutputRoute

    @EnvironmentObject private var appServices: AppServices
    /// The dictation in progress. Held by AppServices so a rebuilt or second window shares it.
    private var session = AppServices.shared.dictationSession
    private var commandModeService: CommandModeService { self.session.commandMode }
    private var rewriteModeService: RewriteModeService { self.session.rewriteMode }
    @StateObject private var meetingHistorySnapshot = MeetingHistorySnapshot()
    @StateObject private var mouseTracker = MousePositionTracker()
    @EnvironmentObject private var menuBarManager: MenuBarManager
    @ObservedObject private var settings = SettingsStore.shared

    /// Computed properties to access shared services from AppServices container
    /// This maintains backward compatibility with the existing code while
    /// removing the duplicate service instances that cause startup crashes.
    private var asr: ASRService { self.session.asr }

    private var audioObserver: AudioHardwareObserver {
        self.appServices.audioObserver
    }

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var hotkeyManager: GlobalHotkeyManager? = nil
    @State private var hotkeyManagerInitialized: Bool = false

    @State private var appear = false
    @State private var accessibilityEnabled = false
    @State private var activeShortcutRecordingTarget: ShortcutRecordingTarget? = nil
    @State private var currentRecordingModifierKeyCodes: Set<UInt16> = []
    @State private var pendingModifierKeyCodes: Set<UInt16> = []
    @State private var pendingModifierFlags: NSEvent.ModifierFlags = []
    @State private var pendingModifierKeyCode: UInt16?
    @State private var pendingModifierOnly = false
    @State private var shortcutRecordingMessage: String? = nil
    @State private var shortcutCaptureMonitor: Any?

    @State private var selectedSidebarItem: SidebarItem?
    @State private var previousSidebarItem: SidebarItem? = nil // Track previous for mode transitions
    @State private var settingsNavigation = SettingsNavigationState()
    @State private var settingsSearchQuery = ""
    @State private var settingsSearchScrollRequest = 0
    /// A settings row chosen from the sidebar search, highlighted like a settings
    /// search match until the user searches or leaves settings.
    @State private var settingsRevealTarget: SettingsSearchTarget?
    @ObservedObject private var appSearch = AppSearchService.shared
    @State private var appSearchCursor: AppSearchHit.Target?
    /// A dictionary, vocabulary, punctuation or prompt row chosen from the sidebar
    /// search. The screen it belongs to opens that row and clears this.
    @State private var appSearchRevealTarget: AppSearchHit.Target?
    @State private var appSearchExpanded: Set<AppSearchKind> = []

    @State private var isHelpEntryHovered = false
    @State private var isSettingsEntryHovered = false
    @State private var isSettingsBackHovered = false
    @FocusState private var isSettingsSearchFocused: Bool
    @State private var showsFluidIntelligenceDemo = false
    @State private var showsReleaseHighlights = false

    // Command Mode State
    // @State private var showCommandMode: Bool = false

    // Audio Settings Tab State
    @State private var inputDevices: [AudioDevice.Device] = []
    @State private var outputDevices: [AudioDevice.Device] = []
    // Populated by gated audio initialization; querying Core Audio while SwiftUI
    // constructs this view can race AttributeGraph metadata processing.
    @State private var selectedInputUID: String = ""
    @State private var selectedOutputUID: String = SettingsStore.shared.preferredOutputDeviceUID ?? ""

    // AI Prompts Tab State
    @State private var aiInputText: String = ""
    @State private var aiOutputText: String = ""
    @State private var isCallingAI: Bool = false

    @State private var showRestartPrompt: Bool = false
    @State private var didOpenAccessibilityPane: Bool = false
    private let accessibilityRestartFlagKey = "FluidVoice_AccessibilityRestartPending"
    private let hasAutoRestartedForAccessibilityKey = "FluidVoice_HasAutoRestartedForAccessibility"
    @State private var accessibilityPollingTask: Task<Void, Never>?
    @State private var accessibilityGuidePanel: NSPanel?
    @State private var accessibilityGuideMonitorTask: Task<Void, Never>?
    @State private var accessibilityGuideRequestID: UUID?

    private var isRecordingAnyShortcutCapture: Bool {
        self.activeShortcutRecordingTarget != nil
    }

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var toolbarTrailingInset: CGFloat = 80

    #if DEBUG
    private var dictationModeSwitchOnReadyForTesting: ((ContentView) -> Void)?

    /// Install real SwiftUI state while avoiding the app page's startup/hardware observers.
    static func dictationModeSwitchFixture(
        asr: ASRService,
        hasActiveMode: Bool = true,
        onReady: @escaping (ContentView) -> Void
    ) -> ContentView {
        var view = ContentView()
        view.dictationModeSwitchOnReadyForTesting = onReady
        view.session = DictationSession(asr: asr)
        view.session.activeRecordingMode = hasActiveMode ? .edit : .none
        view.session.isRecordingForRewrite = hasActiveMode
        return view
    }

    func beginDictationModeSwitchForTesting(selection: SettingsStore.DictationPromptSelection? = nil) -> Task<Void, Never>? {
        if let selection { return self.session.beginDictationRecording(for: selection, mode: .promptMode) }
        return self.session.beginDictationRecording(for: .primary, mode: .dictate)
    }

    func blockDictationModeSwitchForTesting(savingCancellation: Bool = false, processing: Bool = false) {
        self.session.isSavingCancelledRecording = savingCancellation
        self.session.processingDictationLifecycleID = processing ? self.session.overlayLifecycleID : nil
    }

    var dictationModeSwitchStateForTesting: (mode: String, slot: SettingsStore.DictationShortcutSlot?, generation: UInt64) {
        (self.session.activeRecordingMode.rawValue, self.session.activeDictationShortcutSlot, self.session.overlayLifecycleID)
    }
    #endif

    @ViewBuilder
    var body: some View {
        #if DEBUG
        if let onReady = self.dictationModeSwitchOnReadyForTesting {
            Color.clear.onAppear {
                self.session.menuBarManager = self.menuBarManager
                onReady(self)
            }
        } else {
            self.appBody
        }
        #else
        self.appBody
        #endif
    }

    private var appBody: some View {
        let layout = AnyView(
            Group {
                if self.settings.shouldShowOnboarding {
                    self.onboardingOnlyView
                } else {
                    NavigationSplitView(columnVisibility: self.$columnVisibility) {
                        self.sidebarContent
                            .frame(minWidth: 264, maxWidth: 360)
                            .navigationSplitViewColumnWidth(min: 264, ideal: 300, max: 360)
                            .toolbar(removing: .sidebarToggle)
                    } detail: {
                        self.detailView
                            .onGeometryChange(for: CGFloat.self) { geometry in
                                (geometry.size.width * 0.1).rounded()
                            } action: { inset in
                                self.toolbarTrailingInset = inset
                            }
                    }
                    .navigationSplitViewStyle(.balanced)
                }
            }
        )

        let tracked = layout.withMouseTracking(self.mouseTracker)
        let env = tracked.environmentObject(self.mouseTracker)
        let nav = env.onChange(of: self.menuBarManager.requestedNavigationDestination) { _, destination in
            self.handleMenuBarNavigation(destination)
        }
        let sized = nav.fluidWindowSizing(self.windowSizing)

        let observed = self.applyShortcutStateChanges(to: sized)
        let withToolbar = self.applyMainWindowToolbar(to: observed)

        return withToolbar
            .environment(\.fluidToolbarTrailingInset, self.toolbarTrailingInset)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                self.refreshAccessibilityPermissionState()
            }
            .onReceive(NotificationCenter.default.publisher(for: .openCustomDictionaryFromVoiceEngine)) { _ in
                self.navigateToApp(.customDictionary)
            }
            .onReceive(NotificationCenter.default.publisher(for: .appNavigationRequested)) { _ in
                self.handlePendingAppNavigation()
            }
            .onReceive(NotificationCenter.default.publisher(for: .dictationPromptShortcutsChanged)) { _ in
                self.hotkeyManager?.updatePromptShortcutAssignments(SettingsStore.shared.dictationPromptShortcutAssignments())
            }
            // Local UI diagnostics, same defaults gate as GlobalHotkeyManager+DebugTrigger.
            .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("com.FluidApp.debug.toggleSidebar"))) { _ in
                guard UserDefaults.standard.bool(forKey: "FluidDebugRemoteToggleEnabled") else { return }
                self.toggleSidebar()
            }
            .onReceive(DistributedNotificationCenter.default().publisher(for: Notification.Name("com.FluidApp.debug.openSettings"))) { _ in
                guard UserDefaults.standard.bool(forKey: "FluidDebugRemoteToggleEnabled") else { return }
                self.menuBarManager.openPreferencesFromUI()
            }
            .onReceive(NotificationCenter.default.publisher(for: .settingsBackupDidRestore)) { _ in
                self.reloadSettingsStateAfterBackupRestore()
            }
            .onReceive(self.asr.$partialTranscription) { text in
                self.session.handleSpokenSendPartialTranscription(text)
            }
            .overlay(alignment: .center) {}
            .modifier(ReleaseHighlightsPresenter(
                requested: self.$showsReleaseHighlights,
                // The current highlights only point at meetings.
                isEligible: FluidWisprBuild.includesMeetings && !self.settings.shouldShowOnboarding && !self.showsFluidIntelligenceDemo &&
                    !self.asr.isRunningOrStarting && self.asr.activeExclusiveActivity == nil &&
                    !self.asr.showError && !self.showRestartPrompt,
                onExplore: self.navigateToApp
            ))
            .sheet(isPresented: self.$showsFluidIntelligenceDemo) {
                FluidIntelligenceDemoView(
                    asr: self.asr,
                    onStart: { _ = self.session.startRecording() },
                    onStop: { await self.session.stopAndProcessTranscription() },
                    onCancel: { _ = self.handleCancelShortcut() },
                    onSetup: {
                        self.showsFluidIntelligenceDemo = false
                        self.navigateToApp(.aiEnhancements)
                    },
                    runExample: { text, model in
                        try await self.session.processTextWithAI(text, overrideProviderID: PrivateAIProviderFeature.shared.providerID, overrideModel: model, dictationSlot: .primary)
                    }
                )
            }
            .onChange(of: self.showsFluidIntelligenceDemo) { _, isShowing in
                self.session.isFluidIntelligenceDemoShowing = isShowing
            }
            .alert(
                self.asr.errorTitle,
                isPresented: Binding(
                    get: { self.asr.showError },
                    set: { self.asr.showError = $0 }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(self.asr.errorMessage)
            }
            .onChange(of: self.audioObserver.changeTick) { _, _ in
                // Hardware change detected → refresh device lists
                self.refreshDevices()

                if let sysOut = AudioDevice.getDefaultOutputDevice()?.uid {
                    self.selectedOutputUID = sysOut
                }
            }
            .onChange(of: self.audioObserver.inputAvailabilityTick) { _, _ in
                self.refreshInputDevices()
            }
            .onDisappear {
                Task { await self.asr.stopWithoutTranscription() }
                self.session.cancelPrewarmDictationIfNeeded()
                // The sheet goes away with the window; a stale flag would block every later hotkey start.
                self.session.isFluidIntelligenceDemoShowing = false
                // Note: Overlay lifecycle is now managed by MenuBarManager
                // Note: NotchContentState handlers capture self (a struct value copy) and are
                // intentionally kept alive so the overlay remains fully functional when the
                // settings window is closed. No retain cycle risk since ContentView is a value type.

                // Stop accessibility polling
                self.finishAccessibilityPermissionFlow()
                self.removeShortcutCaptureMonitor()
            }
            .onChange(of: self.primaryDictationShortcuts) { _, newValue in
                let display = newValue.map(\.displayString).joined(separator: ", ")
                DebugLogger.shared.debug("Primary dictation shortcuts changed to \(display)", source: "ContentView")
                self.hotkeyManager?.updatePrimaryShortcuts(newValue)

                // Update initialization status after shortcut change
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.hotkeyManagerInitialized = self.hotkeyManager?.validateEventTapHealth() ?? false
                    DebugLogger.shared.debug(
                        "Hotkey manager initialized: \(self.hotkeyManagerInitialized)",
                        source: "ContentView"
                    )
                }
            }
            .onChange(of: self.selectedSidebarItem) { _, newValue in
                self.handleModeTransition(from: self.previousSidebarItem, to: newValue)
                self.previousSidebarItem = newValue
            }
    }

    private func applyShortcutStateChanges<Content: View>(to view: Content) -> some View {
        view
            .onAppear {
                self.handleContentAppear()
            }
            .onChange(of: self.accessibilityEnabled) { _, enabled in
                if enabled {
                    self.finishAccessibilityPermissionFlow()
                }

                if enabled && self.hotkeyManager != nil && !self.hotkeyManagerInitialized {
                    DebugLogger.shared.debug("Accessibility enabled, reinitializing hotkey manager", source: "ContentView")
                    self.hotkeyManager?.reinitialize()
                }
            }
            .onChange(of: self.activeShortcutRecordingTarget) { _, _ in
                self.hotkeyManager?.resetModifierOnlyShortcutTracking()
            }
            .onChange(of: self.promptModeHotkeyShortcut) { _, newValue in
                self.hotkeyManager?.updatePromptModeShortcut(newValue)
            }
            .onChange(of: self.commandModeHotkeyShortcut) { _, newValue in
                self.hotkeyManager?.updateCommandModeShortcut(newValue)
            }
            .onChange(of: self.rewriteModeHotkeyShortcut) { _, newValue in
                self.hotkeyManager?.updateRewriteModeShortcut(newValue)
            }
            .onChange(of: self.hotkeyMode) { _, newValue in
                self.hotkeyManager?.setHotkeyMode(newValue)
            }
            .onChange(of: self.isPromptModeShortcutEnabled) { newValue in
                self.handlePromptShortcutEnabledChange(newValue)
            }
            .onChange(of: self.isCommandModeShortcutEnabled) { newValue in
                self.handleCommandShortcutEnabledChange(newValue)
            }
            .onChange(of: self.isRewriteModeShortcutEnabled) { newValue in
                self.handleRewriteShortcutEnabledChange(newValue)
            }
            .onChange(of: self.pasteLastTranscriptionHotkeyShortcut) { _, _ in
                self.hotkeyManager?.refreshMouseShortcutTapIfNeeded()
            }
            .onChange(of: self.isPasteLastTranscriptionShortcutEnabled) { newValue in
                self.handlePasteLastTranscriptionShortcutEnabledChange(newValue)
            }
    }

    private func handlePasteLastTranscriptionShortcutEnabledChange(_ isEnabled: Bool) {
        self.hotkeyManager?.refreshMouseShortcutTapIfNeeded()
        if !isEnabled, self.activeShortcutRecordingTarget == .pasteLast {
            self.clearShortcutRecordingMode()
        }
    }

    private func handlePromptShortcutEnabledChange(_ isEnabled: Bool) {
        self.hotkeyManager?.updatePromptModeShortcutEnabled(isEnabled)

        if !isEnabled {
            if self.activeShortcutRecordingTarget == .secondaryDictation {
                self.clearShortcutRecordingMode()
            }

            if self.session.activeRecordingMode == .promptMode {
                if self.asr.isRunning {
                    Task { await self.asr.stopWithoutTranscription() }
                }
                self.session.cancelPrewarmDictationIfNeeded()
                self.session.clearActiveRecordingMode()
                self.menuBarManager.setOverlayMode(.dictation)
            }
        }
    }

    private func handleCommandShortcutEnabledChange(_ isEnabled: Bool) {
        self.hotkeyManager?.updateCommandModeShortcutEnabled(isEnabled)

        if !isEnabled {
            if self.activeShortcutRecordingTarget == .command {
                self.clearShortcutRecordingMode()
            }

            if self.session.activeRecordingMode == .command {
                if self.asr.isRunning {
                    Task { await self.asr.stopWithoutTranscription() }
                }
                self.session.cancelPrewarmDictationIfNeeded()
                self.session.clearActiveRecordingMode()
                self.menuBarManager.setOverlayMode(.dictation)
            }
        }
    }

    private func handleRewriteShortcutEnabledChange(_ isEnabled: Bool) {
        self.hotkeyManager?.updateRewriteModeShortcutEnabled(isEnabled)

        if !isEnabled {
            if self.activeShortcutRecordingTarget == .edit {
                self.clearShortcutRecordingMode()
            }

            if self.session.activeRecordingMode == .edit {
                if self.asr.isRunning {
                    Task { await self.asr.stopWithoutTranscription() }
                }
                self.session.cancelPrewarmDictationIfNeeded()
                self.session.clearActiveRecordingMode()
                self.rewriteModeService.clearState()
                self.menuBarManager.setOverlayMode(.dictation)
            }
        }
    }

    private func handleContentAppear() {
        self.session.menuBarManager = self.menuBarManager
        self.appear = true
        self.refreshAccessibilityPermissionState()

        Task {
            await AudioStartupGate.shared.scheduleOpenAfterInitialUISettled()
        }

        self.handleMenuBarNavigation(self.menuBarManager.requestedNavigationDestination)
        if UserDefaults.standard.bool(forKey: self.accessibilityRestartFlagKey) {
            UserDefaults.standard.set(false, forKey: self.accessibilityRestartFlagKey)
            self.showRestartPrompt = false
        }

        if self.accessibilityEnabled {
            self.finishAccessibilityPermissionFlow()
        }

        if self.selectedSidebarItem == nil, !self.settingsNavigation.isPresented {
            self.selectedSidebarItem = .welcome
        }
        self.handlePendingAppNavigation()

        if !self.accessibilityEnabled {
            UserDefaults.standard.set(false, forKey: self.hasAutoRestartedForAccessibilityKey)
        }

        self.menuBarManager.initializeMenuBar()
        self.scheduleDelayedAudioInitialization()
        self.configureNotchCallbacks()
        self.startAccessibilityPolling()
        self.initializeHotkeyManagerIfNeeded()

        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await self.preloadASRModel()
        }

        SettingsStore.shared.normalizeProviderModelSelections()
        self.installShortcutCaptureMonitor()
    }

    private func scheduleDelayedAudioInitialization() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            DebugLogger.shared.info("🚦 Startup delay complete, signaling UI ready...", source: "ContentView")
            self.appServices.signalUIReady()
            self.menuBarManager.configure(
                meetingCoordinator: self.appServices.meetingSessionCoordinator
            )

            Task { @MainActor in
                await AudioStartupGate.shared.scheduleOpenAfterInitialUISettled()
                await AudioStartupGate.shared.waitUntilOpen()

                DebugLogger.shared.info("🔊 Starting gated audio initialization...", source: "ContentView")
                self.audioObserver.startObserving()
                await self.asr.initialize()
                self.menuBarManager.configure(asrService: self.appServices.asr)
                self.refreshDevices()

                if self.selectedOutputUID.isEmpty, let defOut = AudioDevice.getDefaultOutputDevice()?.uid {
                    self.selectedOutputUID = defOut
                }

                if let prefOut = SettingsStore.shared.preferredOutputDeviceUID,
                   !prefOut.isEmpty,
                   outputDevices.first(where: { $0.uid == prefOut }) != nil
                {
                    self.selectedOutputUID = prefOut
                }

                DebugLogger.shared.info("✅ Audio subsystems initialized", source: "ContentView")
            }
        }
    }

    private func configureNotchCallbacks() {
        NotchOverlayManager.shared.onNotchClicked = {
            guard NotchOverlayManager.shared.canHandleNotchCommandTap else { return }
            if NotchOverlayManager.shared.canShowExpandedCommandOutput,
               !NotchContentState.shared.commandConversationHistory.isEmpty
            {
                NotchOverlayManager.shared.showExpandedCommandOutput()
            }
        }

        NotchOverlayManager.shared.onCommandFollowUp = { [weak commandModeService] text in
            guard NotchOverlayManager.shared.allowsCommandNotchActions, let commandModeService else { return false }
            let accepted = await commandModeService.processFollowUpCommand(text)
            if !accepted, commandModeService.pendingCommand != nil {
                self.asr.errorTitle = "Command Awaiting Approval"
                self.asr.errorMessage = "Approve or cancel the pending command before sending a follow-up. Your text has been kept."
                self.asr.showError = true
            }
            return accepted
        }

        NotchOverlayManager.shared.onNewChat = { [weak commandModeService] in
            guard NotchOverlayManager.shared.allowsCommandNotchActions else { return }
            commandModeService?.createNewChat()
        }

        NotchOverlayManager.shared.onSwitchChat = { [weak commandModeService] chatID in
            guard NotchOverlayManager.shared.allowsCommandNotchActions else { return }
            commandModeService?.switchToChat(id: chatID)
        }

        NotchOverlayManager.shared.onClearChat = { [weak commandModeService] in
            guard NotchOverlayManager.shared.allowsCommandNotchActions else { return }
            commandModeService?.deleteCurrentChat()
        }
    }

    private func installShortcutCaptureMonitor() {
        self.removeShortcutCaptureMonitor()
        self.shortcutCaptureMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { event in
            self.handleShortcutCaptureEvent(event)
        }
    }

    private func removeShortcutCaptureMonitor() {
        guard let monitor = self.shortcutCaptureMonitor else { return }
        NSEvent.removeMonitor(monitor)
        self.shortcutCaptureMonitor = nil
    }

    private func handleShortcutCaptureEvent(_ event: NSEvent) -> NSEvent? {
        let eventModifiers = event.modifierFlags.intersection([.function, .command, .option, .control, .shift])
        let isRecordingAnyShortcut = self.isRecordingAnyShortcutCapture
        let recordingTarget = self.activeShortcutRecordingTarget

        if event.type == .keyDown {
            return self.handleShortcutKeyDownEvent(event, modifiers: eventModifiers, isRecordingAnyShortcut: isRecordingAnyShortcut, recordingTarget: recordingTarget)
        } else if event.type == .flagsChanged {
            return self.handleShortcutFlagsChangedEvent(event, modifiers: eventModifiers, isRecordingAnyShortcut: isRecordingAnyShortcut, recordingTarget: recordingTarget)
        } else if event.type == .leftMouseDown || event.type == .rightMouseDown || event.type == .otherMouseDown {
            return self.handleShortcutMouseDownEvent(event, modifiers: eventModifiers, isRecordingAnyShortcut: isRecordingAnyShortcut, recordingTarget: recordingTarget)
        }

        return event
    }

    private func handleShortcutKeyDownEvent(
        _ event: NSEvent,
        modifiers eventModifiers: NSEvent.ModifierFlags,
        isRecordingAnyShortcut: Bool,
        recordingTarget: ShortcutRecordingTarget?
    ) -> NSEvent? {
        guard isRecordingAnyShortcut else {
            if self.cancelRecordingHotkeyShortcut?.matches(keyCode: event.keyCode, modifiers: eventModifiers) == true,
               self.handleCancelShortcut()
            {
                return nil
            }
            self.shortcutRecordingMessage = nil
            self.resetPendingShortcutState()
            return event
        }

        let keyCode = event.keyCode
        if keyCode == 53, eventModifiers.isEmpty, recordingTarget != .cancel {
            DebugLogger.shared.debug("NSEvent monitor: Escape pressed, cancelling shortcut recording", source: "ContentView")
            self.clearShortcutRecordingMode()
            return nil
        }

        let newShortcut = HotkeyShortcut(keyCode: keyCode, modifierFlags: eventModifiers)
        if recordingTarget != .cancel, recordingTarget != .pasteLast, newShortcut.requiresModifierForRecording {
            self.shortcutRecordingMessage = "\(newShortcut.displayString) needs a modifier key"
            self.resetPendingShortcutState()
            return nil
        }
        DebugLogger.shared.debug("NSEvent monitor: Recording new shortcut: \(newShortcut.displayString)", source: "ContentView")

        if let recordingTarget,
           let conflictMessage = self.shortcutConflictMessage(for: newShortcut, target: recordingTarget)
        {
            self.shortcutRecordingMessage = conflictMessage
            self.resetPendingShortcutState()
            DebugLogger.shared.debug("NSEvent monitor: Shortcut conflict while recording: \(conflictMessage)", source: "ContentView")
            return nil
        }

        self.shortcutRecordingMessage = nil
        if let recordingTarget {
            self.assignRecordedShortcut(newShortcut, to: recordingTarget)
        }
        self.resetPendingShortcutState()
        DebugLogger.shared.debug("NSEvent monitor: Finished recording shortcut", source: "ContentView")
        return nil
    }

    private func handleShortcutMouseDownEvent(
        _ event: NSEvent,
        modifiers eventModifiers: NSEvent.ModifierFlags,
        isRecordingAnyShortcut: Bool,
        recordingTarget: ShortcutRecordingTarget?
    ) -> NSEvent? {
        guard isRecordingAnyShortcut else {
            self.shortcutRecordingMessage = nil
            self.resetPendingShortcutState()
            return event
        }

        let newShortcut = HotkeyShortcut(mouseButton: event.buttonNumber, modifierFlags: eventModifiers)
        DebugLogger.shared.debug("NSEvent monitor: Recording new mouse shortcut: \(newShortcut.displayString)", source: "ContentView")

        if newShortcut.isUnmodifiedLeftOrRightClick, let mouseButton = newShortcut.mouseButton {
            self.shortcutRecordingMessage = "\(HotkeyShortcut.mouseButtonToString(mouseButton)) needs a modifier key"
            self.resetPendingShortcutState()
            return event
        }

        if let recordingTarget,
           let conflictMessage = self.shortcutConflictMessage(for: newShortcut, target: recordingTarget)
        {
            self.shortcutRecordingMessage = conflictMessage
            self.resetPendingShortcutState()
            DebugLogger.shared.debug("NSEvent monitor: Mouse shortcut conflict while recording: \(conflictMessage)", source: "ContentView")
            return nil
        }

        self.shortcutRecordingMessage = nil
        if let recordingTarget {
            self.assignRecordedShortcut(newShortcut, to: recordingTarget)
        }
        self.resetPendingShortcutState()
        DebugLogger.shared.debug("NSEvent monitor: Finished recording mouse shortcut", source: "ContentView")
        return nil
    }

    private func handleShortcutFlagsChangedEvent(
        _ event: NSEvent,
        modifiers eventModifiers: NSEvent.ModifierFlags,
        isRecordingAnyShortcut: Bool,
        recordingTarget: ShortcutRecordingTarget?
    ) -> NSEvent? {
        guard isRecordingAnyShortcut else {
            self.shortcutRecordingMessage = nil
            self.resetPendingShortcutState()
            return event
        }

        let changedModifierFlag = HotkeyShortcut.modifierFlag(forKeyCode: event.keyCode)

        if eventModifiers.isEmpty {
            if self.pendingModifierOnly, let modifierKeyCode = pendingModifierKeyCode {
                let newShortcut = HotkeyShortcut(
                    keyCode: modifierKeyCode,
                    modifierFlags: self.pendingModifierFlags,
                    modifierKeyCodes: Array(self.pendingModifierKeyCodes)
                )
                DebugLogger.shared.debug("NSEvent monitor: Recording modifier-only shortcut: \(newShortcut.displayString)", source: "ContentView")

                if let recordingTarget,
                   let conflictMessage = self.shortcutConflictMessage(for: newShortcut, target: recordingTarget)
                {
                    self.shortcutRecordingMessage = conflictMessage
                    self.resetPendingShortcutState()
                    DebugLogger.shared.debug("NSEvent monitor: Modifier shortcut conflict while recording: \(conflictMessage)", source: "ContentView")
                    return nil
                }

                self.shortcutRecordingMessage = nil
                if let recordingTarget {
                    self.assignRecordedShortcut(newShortcut, to: recordingTarget)
                }
                self.resetPendingShortcutState()
                DebugLogger.shared.debug("NSEvent monitor: Finished recording modifier shortcut", source: "ContentView")
                return nil
            }

            self.resetPendingShortcutState()
            DebugLogger.shared.debug("NSEvent monitor: Modifiers released without recording, continuing to wait", source: "ContentView")
            return nil
        }

        if let changedModifierFlag {
            let isRelease = self.currentRecordingModifierKeyCodes.contains(event.keyCode)

            if isRelease {
                self.currentRecordingModifierKeyCodes.remove(event.keyCode)
            } else if eventModifiers.contains(changedModifierFlag) {
                self.currentRecordingModifierKeyCodes.insert(event.keyCode)
                self.pendingModifierKeyCodes.insert(event.keyCode)
                self.pendingModifierFlags = self.pendingModifierFlags.union(eventModifiers)
                self.pendingModifierKeyCode = event.keyCode
                self.pendingModifierOnly = true
                DebugLogger.shared.debug("NSEvent monitor: Modifier key pressed during recording, pending modifiers: \(self.pendingModifierFlags)", source: "ContentView")
            }
        }
        return nil
    }

    // MARK: - Analytics helpers

    // MARK: - Mode Transition Handler

    /// Centralized handler for sidebar mode transitions to ensure proper cleanup and state management
    private func handleModeTransition(from oldValue: SidebarItem?, to newValue: SidebarItem?) {
        DebugLogger.shared.debug("Mode transition: \(String(describing: oldValue)) → \(String(describing: newValue))", source: "ContentView")

        if oldValue != newValue {
            self.clearShortcutRecordingMode()
        }

        // Clean up state from the previous mode
        if let old = oldValue {
            switch old {
            case .commandMode:
                // Close expanded command output notch if visible
                if NotchOverlayManager.shared.isCommandOutputExpanded {
                    DebugLogger.shared.debug("Closing expanded command notch on mode transition", source: "ContentView")
                    NotchOverlayManager.shared.hideExpandedCommandOutput()
                }
                // Note: We don't clear command history here - user may want to return to it

            case .rewriteMode:
                // Clear rewrite state when leaving
                self.rewriteModeService.clearState()

            default:
                break
            }
        }

        // Set up state for the new mode
        if let new = newValue {
            switch new {
            case .commandMode:
                self.menuBarManager.setOverlayMode(.command)

            case .rewriteMode:
                self.menuBarManager.setOverlayMode(.edit)

            default:
                // For all other views, set to dictation mode
                self.menuBarManager.setOverlayMode(.dictation)
            }
        } else {
            // If newValue is nil, default to dictation
            self.menuBarManager.setOverlayMode(.dictation)
        }
    }

    @MainActor
    private func handleMenuBarNavigation(_ destination: MenuBarNavigationDestination?) {
        guard let destination else { return }
        guard !self.settings.shouldShowOnboarding else { return }

        switch destination {
        case .customDictionary:
            self.navigateToApp(.customDictionary)
        case .microphoneSettings:
            self.openSettings(.audio)
        case .settings:
            self.openSettings(.general)
        case .meetingTranscription:
            self.navigateToApp(.meetingTranscription)
        case .preferences:
            self.openSettings(.general)
        }
    }

    private func handlePendingAppNavigation() {
        guard let destination = AppNavigationRouter.shared.consumePendingDestination() else { return }

        switch destination {
        case .aiEnhancements:
            self.navigateToApp(.aiEnhancements)
        case .history:
            self.navigateToApp(.history)
        case .dictationShortcuts:
            self.openSettings(.shortcuts)
        case .meetingTranscription:
            self.navigateToApp(.meetingTranscription)
        }
    }

    private func navigateToApp(_ destination: SidebarItem) {
        self.clearShortcutRecordingMode()
        self.resetSettingsSearch()
        self.settingsNavigation.leaveForApp()
        self.selectedSidebarItem = destination.shownInThisBuild
    }

    private func openSettings(_ section: SettingsSection) {
        self.clearShortcutRecordingMode()
        self.resetSettingsSearch()
        self.settingsNavigation.present(section, returningTo: self.selectedSidebarItem)
    }

    private func closeSettings() {
        self.clearShortcutRecordingMode()
        self.resetSettingsSearch()
        self.selectedSidebarItem = self.settingsNavigation.dismiss()
    }

    private func resetSettingsSearch() {
        self.settingsSearchQuery = ""
        self.settingsRevealTarget = nil
        self.settingsSearchScrollRequest += 1
    }

    private func resetPendingShortcutState() {
        self.currentRecordingModifierKeyCodes = []
        self.pendingModifierKeyCodes = []
        self.pendingModifierFlags = []
        self.pendingModifierKeyCode = nil
        self.pendingModifierOnly = false
    }

    private func shortcutConflictMessage(for shortcut: HotkeyShortcut, target: ShortcutRecordingTarget) -> String? {
        if shortcut.isMouseShortcut {
            guard target.allowsMouseShortcut else {
                return "Mouse clicks can only be assigned to Primary Dictation or Paste Last Transcription"
            }

            if shortcut.isUnmodifiedLeftOrRightClick, let mouseButton = shortcut.mouseButton {
                return "\(HotkeyShortcut.mouseButtonToString(mouseButton)) needs a modifier key"
            }
        }

        let replacingPrimaryIndex = target.primaryDictationReplacementIndex
        for (index, configuredShortcut) in self.primaryDictationShortcuts.enumerated() where replacingPrimaryIndex != index {
            if configuredShortcut == shortcut {
                return "Duplicate with Primary Dictation Shortcut"
            }
            if shortcut.conflictsWith(configuredShortcut) {
                return "Overlaps Primary Dictation Shortcut — use a different modifier key"
            }
        }

        var configuredShortcuts: [(ShortcutRecordingTarget, HotkeyShortcut)] = []
        if self.isRewriteModeShortcutEnabled {
            configuredShortcuts.append((.edit, self.rewriteModeHotkeyShortcut))
        }
        if self.isPromptModeShortcutEnabled {
            configuredShortcuts.append((.secondaryDictation, self.promptModeHotkeyShortcut))
        }
        let optionalConfiguredShortcuts: [(ShortcutRecordingTarget, HotkeyShortcut?)] = [
            (.cancel, self.cancelRecordingHotkeyShortcut),
            (.command, self.commandModeHotkeyShortcut),
            (.pasteLast, self.pasteLastTranscriptionHotkeyShortcut),
        ]

        for (otherTarget, configuredShortcut) in configuredShortcuts where otherTarget != target {
            if configuredShortcut == shortcut {
                return "Duplicate with \(otherTarget.title)"
            }
            if shortcut.conflictsWith(configuredShortcut) {
                return "Overlaps \(otherTarget.title) — use a different modifier key"
            }
        }
        for (otherTarget, configuredShortcut) in optionalConfiguredShortcuts where otherTarget != target {
            guard let configuredShortcut else { continue }
            if configuredShortcut == shortcut {
                return "Duplicate with \(otherTarget.title)"
            }
            if shortcut.conflictsWith(configuredShortcut) {
                return "Overlaps \(otherTarget.title) — use a different modifier key"
            }
        }

        let targetPromptKey = target.promptConfigurationKey
        for assignment in SettingsStore.shared.dictationPromptShortcutAssignments() {
            guard let key = SettingsStore.shared.dictationPromptConfigurationKey(for: assignment.selection),
                  key != targetPromptKey
            else {
                continue
            }
            if assignment.shortcut == shortcut {
                return "Duplicate with Prompt Shortcut"
            }
            if shortcut.conflictsWith(assignment.shortcut) {
                return "Overlaps Prompt Shortcut — use a different modifier key"
            }
        }

        return nil
    }

    private func assignRecordedShortcut(_ shortcut: HotkeyShortcut, to target: ShortcutRecordingTarget) {
        self.applyRecordedShortcut(shortcut, to: target)
        if target.enablesFeatureOnAssignment {
            self.setShortcutTargetEnabled(true, for: target)
        }
        self.setShortcutRecording(false, for: target)
    }

    private func applyRecordedShortcut(_ shortcut: HotkeyShortcut, to target: ShortcutRecordingTarget) {
        switch target {
        case let .primaryDictation(edit):
            self.applyPrimaryDictationShortcut(shortcut, edit: edit)
        case .secondaryDictation:
            self.promptModeHotkeyShortcut = shortcut
        case .command:
            self.commandModeHotkeyShortcut = shortcut
        case .edit:
            self.rewriteModeHotkeyShortcut = shortcut
        case .cancel:
            self.cancelRecordingHotkeyShortcut = shortcut
        case .pasteLast:
            self.pasteLastTranscriptionHotkeyShortcut = shortcut
        case let .dictationPrompt(key):
            guard let selection = SettingsStore.shared.dictationPromptSelection(forConfigurationKey: key) else { return }
            var configuration = SettingsStore.shared.dictationPromptConfiguration(for: selection)
            configuration.shortcut = shortcut
            SettingsStore.shared.setDictationPromptConfiguration(configuration, for: selection)
            self.hotkeyManager?.updatePromptShortcutAssignments(SettingsStore.shared.dictationPromptShortcutAssignments())
        case .newPrompt:
            NotificationCenter.default.post(
                name: .newPromptShortcutRecorded,
                object: nil,
                userInfo: ["shortcut": shortcut]
            )
        }
    }

    private func applyPrimaryDictationShortcut(_ shortcut: HotkeyShortcut, edit: PrimaryDictationShortcutEdit) {
        var shortcuts = self.primaryDictationShortcuts
        switch edit {
        case .add:
            shortcuts.append(shortcut)
        case let .replace(index):
            if shortcuts.indices.contains(index) {
                shortcuts[index] = shortcut
            } else {
                shortcuts.append(shortcut)
            }
        }
        self.primaryDictationShortcuts = shortcuts
    }

    private func setShortcutTargetEnabled(_ enabled: Bool, for target: ShortcutRecordingTarget) {
        switch target {
        case .secondaryDictation:
            self.isPromptModeShortcutEnabled = enabled
        case .command:
            self.isCommandModeShortcutEnabled = enabled
        case .edit:
            self.isRewriteModeShortcutEnabled = enabled
        case .pasteLast:
            self.isPasteLastTranscriptionShortcutEnabled = enabled
        case .primaryDictation, .cancel, .dictationPrompt, .newPrompt:
            break
        }
    }

    private func setShortcutRecording(_ isRecording: Bool, for target: ShortcutRecordingTarget) {
        if isRecording {
            self.activeShortcutRecordingTarget = target
        } else if self.activeShortcutRecordingTarget == target {
            self.activeShortcutRecordingTarget = nil
        }
    }

    private func clearShortcutRecordingMode() {
        self.activeShortcutRecordingTarget = nil
        self.shortcutRecordingMessage = nil
        self.resetPendingShortcutState()
    }

    private func openIssueReportingPage() {
        guard let url = URL(string: "https://github.com/altic-dev/Fluid-oss/issues/new/choose") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openHelpDocumentation() {
        guard let url = URL(string: "https://docs.altic.dev/") else { return }
        NSWorkspace.shared.open(url)
    }

    private var sidebarContent: some View {
        ZStack {
            // Keep both sidebars mounted so navigation feedback never waits on view construction.
            self.appSidebarView
                .opacity(self.settingsNavigation.isPresented ? 0 : 1)
                .offset(x: self.settingsNavigation.isPresented ? -self.sidebarTransitionDistance : 0)
                .allowsHitTesting(!self.settingsNavigation.isPresented)
                .accessibilityHidden(self.settingsNavigation.isPresented)

            // No flat backdrop: the settings sidebar shows the same system material as the app one.
            self.settingsSidebarView
                .opacity(self.settingsNavigation.isPresented ? 1 : 0)
                .offset(x: self.settingsNavigation.isPresented ? 0 : self.sidebarTransitionDistance)
                .allowsHitTesting(self.settingsNavigation.isPresented)
                .accessibilityHidden(!self.settingsNavigation.isPresented)
        }
        .clipped()
        .tint(self.theme.palette.accent)
        .animation(self.modeTransitionAnimation, value: self.settingsNavigation.isPresented)
    }

    private var appSidebarView: some View {
        VStack(spacing: 0) {
            SidebarSearchField(
                text: self.$appSearch.query,
                placeholder: "Search",
                isActive: !self.settingsNavigation.isPresented,
                onCommand: self.handleAppSearchCommand
            )
            .padding(.horizontal, self.theme.metrics.spacing.md)
            .padding(.top, self.theme.metrics.spacing.sm)
            .padding(.bottom, self.theme.metrics.spacing.sm)

            Group {
                if self.isAppSearchActive {
                    AppSearchResultsView(
                        service: self.appSearch,
                        cursor: self.$appSearchCursor,
                        expanded: self.$appSearchExpanded,
                        open: self.open(searchHit:)
                    )
                } else {
                    self.appSidebarSections
                }
            }
            .frame(maxHeight: .infinity)
            .clipped()

            // Reserve real layout space for the footer. A safe-area inset can let
            // the native sidebar list draw its last rows beneath these controls.
            VStack(spacing: 0) {
                self.helpEntryButton
                self.settingsEntryButton
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: self.appSearch.groups) {
            self.appSearchCursor = nil
            self.appSearchExpanded = []
        }
    }

    private var isAppSearchActive: Bool {
        !self.appSearch.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var appSidebarSections: some View {
        List(selection: self.$selectedSidebarItem) {
            Section {
                self.sidebarNavigationLink(.welcome, title: "Dashboard", systemImage: "house.fill")
                self.sidebarNavigationLink(.history, title: "History", systemImage: "clock.arrow.circlepath")
                self.sidebarNavigationLink(.stats, title: "Stats", systemImage: "chart.bar.fill")
            } header: {
                self.sidebarSectionHeader("Activity")
            }

            Section {
                self.sidebarNavigationLink(.voiceEngine, title: "Voice Engine", systemImage: "waveform")
                self.sidebarNavigationLink(.aiEnhancements, title: "AI Providers", systemImage: "cpu")
                self.sidebarNavigationLink(.cleanupStyles, title: "Cleanup Styles", systemImage: "wand.and.stars")
                self.sidebarNavigationLink(.customDictionary, title: "Custom Dictionary", systemImage: "text.book.closed.fill")
            } header: {
                self.sidebarSectionHeader("Configure")
            }

            if !FluidWisprBuild.isLean {
                Section {
                    self.sidebarNavigationLink(.commandMode, title: "Command Mode", systemImage: "terminal.fill")
                    self.sidebarNavigationLink(.fileTranscription, title: "File Transcription", systemImage: "doc.text.fill")
                    self.sidebarNavigationLink(
                        .meetingTranscription,
                        title: "FluidMeet",
                        systemImage: "person.2.fill"
                    )
                } header: {
                    self.sidebarSectionHeader("Use")
                }
            }

            Section {
                self.sidebarNavigationLink(.changelog, title: "Change logs", systemImage: "doc.text.magnifyingglass")
                self.sidebarNavigationLink(.feedback, title: "Feedback", systemImage: "envelope.fill")
            } header: {
                self.sidebarSectionHeader("Help")
            }
        }
        .listStyle(.sidebar)
        .accentColor(self.theme.palette.accent)
        .animation(nil, value: self.selectedSidebarItem)
    }

    // MARK: - App search

    /// Up and Down move the cursor through the visible rows, Return opens the
    /// cursor or the first row. Anything else is left to the field.
    private func handleAppSearchCommand(_ selector: Selector) -> Bool {
        let hits = AppSearchResultsView.visibleHits(self.appSearch.groups, expanded: self.appSearchExpanded)
        guard !hits.isEmpty else { return false }
        let position = hits.firstIndex { $0.target == self.appSearchCursor }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            self.appSearchCursor = hits[min((position ?? -1) + 1, hits.count - 1)].target
        case #selector(NSResponder.moveUp(_:)):
            self.appSearchCursor = hits[max((position ?? hits.count) - 1, 0)].target
        case #selector(NSResponder.insertNewline(_:)):
            self.open(searchHit: hits[position ?? 0])
        default:
            return false
        }
        return true
    }

    private func open(searchHit hit: AppSearchHit) {
        switch hit.target {
        case let .history(id):
            TranscriptionHistoryStore.shared.selectEntryFromSearch(id: id)
            self.navigateToApp(.history)
        case let .transcript(id):
            FileTranscriptionHistoryStore.shared.selectedEntryID = id
            self.appSearchRevealTarget = hit.target
            self.navigateToApp(.fileTranscription)
        case let .chat(id):
            self.commandModeService.switchToChat(id: id)
            self.navigateToApp(.commandMode)
        case .dictionaryEntry, .vocabulary, .punctuation:
            self.appSearchRevealTarget = hit.target
            self.navigateToApp(.customDictionary)
        case .prompt:
            self.appSearchRevealTarget = hit.target
            self.navigateToApp(.cleanupStyles)
        case let .settings(target):
            self.openSettings(target.section)
            self.settingsRevealTarget = target
        }
        self.appSearch.query = ""
    }

    private var settingsSidebarView: some View {
        VStack(spacing: 0) {
            Button {
                self.closeSettings()
            } label: {
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    Image(systemName: "chevron.left")
                        .font(.fluidSystem(size: 11, weight: .semibold))
                        .frame(width: 18, height: 28)

                    Text("Back to app")
                        .font(self.theme.typography.sidebarItem)

                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, self.theme.metrics.spacing.md)
                .padding(.top, self.theme.metrics.spacing.sm)
                .padding(.bottom, self.theme.metrics.spacing.xs)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(SidebarChromeButtonStyle(
                isHovered: self.isSettingsBackHovered,
                reduceMotion: self.accessibilityReduceMotion
            ))
            .onHover { self.isSettingsBackHovered = $0 }
            .help("Back to FluidVoice")
            .accessibilityLabel("Back to FluidVoice")

            SidebarSearchField(
                text: Binding(
                    get: { self.settingsSearchQuery },
                    set: { self.updateSettingsSearchQuery($0) }
                ),
                placeholder: "Search Settings",
                isActive: self.settingsNavigation.isPresented
            )
            .padding(.horizontal, self.theme.metrics.spacing.md)
            .padding(.top, self.theme.metrics.spacing.xs)
            .padding(.bottom, self.theme.metrics.spacing.sm)

            List(selection: Binding(
                get: { self.settingsNavigation.selectedSection },
                set: { newValue in
                    guard let newValue else { return }
                    if self.settingsNavigation.isLeaving(.shortcuts, for: newValue) {
                        self.clearShortcutRecordingMode()
                    }
                    self.settingsNavigation.selectedSection = newValue
                    self.settingsSearchScrollRequest += 1
                }
            )) {
                ForEach(self.filteredSettingsSections) { section in
                    let isSelected = self.settingsNavigation.selectedSection == section
                    NavigationLink(value: section) {
                        HStack(spacing: self.theme.metrics.spacing.sm) {
                            Image(systemName: section.systemImage)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                                .frame(width: 18)

                            Text(section.title)
                                .foregroundStyle(isSelected ? Color.white : Color.primary)
                        }
                        .font(self.theme.typography.sidebarItem)
                    }
                    .sidebarOptionHover(
                        isSelected: isSelected,
                        reduceMotion: self.accessibilityReduceMotion
                    )
                }
            }
            .listStyle(.sidebar)
            .accentColor(self.theme.palette.accent)
            .animation(nil, value: self.settingsNavigation.selectedSection)
        }
    }

    private var isSettingsSearchActive: Bool {
        !self.settingsSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var settingsSearchResults: [SettingsSearchResult] {
        if let target = self.settingsRevealTarget {
            return [SettingsSearchResult(target: target, score: 0)]
        }
        return self.availableSettingsSearchResults(for: self.settingsSearchQuery)
    }

    private var filteredSettingsSections: [SettingsSection] {
        guard self.isSettingsSearchActive else { return SettingsSection.allCases }
        let matchingSections = Set(self.settingsSearchResults.map(\.section))
        return SettingsSection.allCases.filter(matchingSections.contains)
    }

    private func updateSettingsSearchQuery(_ query: String) {
        self.settingsSearchQuery = query
        self.settingsRevealTarget = nil
        self.settingsSearchScrollRequest += 1

        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let results = self.availableSettingsSearchResults(for: query)
        self.settingsNavigation.selectedSection = SettingsSearchIndex.preferredSection(
            current: self.settingsNavigation.selectedSection,
            results: results
        )
    }

    private func availableSettingsSearchResults(for query: String) -> [SettingsSearchResult] {
        SettingsSearchIndex.results(
            for: query,
            availability: SettingsSearchAvailability(
                microphoneAuthorized: self.asr.micStatus == .authorized,
                accessibilityEnabled: self.accessibilityEnabled,
                savesTranscriptionHistory: SettingsStore.shared.saveTranscriptionHistory,
                savesAudioWithTranscriptionHistory: SettingsStore.shared.saveAudioWithTranscriptionHistory,
                overlayAtBottom: self.settings.overlayPosition == .bottom
            )
        )
    }

    private var settingsEntryButton: some View {
        Button {
            self.openSettings(.general)
        } label: {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                Image(systemName: "gearshape")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                Text("Settings")

                Spacer(minLength: self.theme.metrics.spacing.sm)

                Image(systemName: "chevron.right")
                    .font(.fluidSystem(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(self.theme.typography.sidebarItem)
            .padding(.horizontal, self.theme.metrics.spacing.md)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarChromeButtonStyle(
            isHovered: self.isSettingsEntryHovered,
            reduceMotion: self.accessibilityReduceMotion
        ))
        .onHover { self.isSettingsEntryHovered = $0 }
        .help("Settings")
        .accessibilityLabel("Settings")
    }

    private var helpEntryButton: some View {
        Menu {
            Button("Documentation", systemImage: "book") { self.openHelpDocumentation() }
            Button("What’s new", systemImage: "gift") { self.showsReleaseHighlights = true }
                .disabled(self.asr.isRunningOrStarting || self.asr.activeExclusiveActivity != nil || NotchContentState.shared.isProcessing)
            if PrivateAIProviderFeature.shared.isAvailable {
                Button("Try Fluid Intelligence", systemImage: "sparkles") { self.showsFluidIntelligenceDemo = true }
                    .disabled(self.asr.isRunningOrStarting || NotchContentState.shared.isProcessing || DictationPromptTestCoordinator.shared.isActive)
            }
            Button("Replay onboarding", systemImage: "arrow.counterclockwise") {
                guard !self.asr.isRunning, !self.asr.isStarting, !NotchContentState.shared.isProcessing else { return }
                self.settings.resetOnboardingProgress()
                self.settings.playgroundUsed = false
            }
            .disabled(self.asr.isRunning || self.asr.isStarting || NotchContentState.shared.isProcessing)
        } label: {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                Image(systemName: "questionmark.circle")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                Text("Help")

                Spacer(minLength: self.theme.metrics.spacing.sm)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.fluidSystem(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(self.theme.typography.sidebarItem)
            .padding(.horizontal, self.theme.metrics.spacing.md)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(SidebarChromeButtonStyle(
            isHovered: self.isHelpEntryHovered,
            reduceMotion: self.accessibilityReduceMotion
        ))
        .onHover { self.isHelpEntryHovered = $0 }
        .help("Open FluidVoice Help")
        .accessibilityLabel("Help")
        .accessibilityHint("What’s new, documentation, Fluid Intelligence demo, and replay onboarding")
    }

    private var modeTransitionAnimation: Animation {
        let duration = self.settingsNavigation.isPresented ? 0.16 : 0.1
        return self.accessibilityReduceMotion
            ? .easeOut(duration: 0.08)
            : .snappy(duration: duration, extraBounce: 0)
    }

    private var sidebarTransitionDistance: CGFloat {
        self.accessibilityReduceMotion ? 0 : 8
    }

    private func sidebarSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(self.theme.typography.sidebarSection)
            .foregroundStyle(.secondary)
            .textCase(nil)
            .padding(.top, self.theme.metrics.spacing.sm)
            .padding(.bottom, self.theme.metrics.spacing.xs)
    }

    private func sidebarNavigationLink(_ item: SidebarItem, title: String, systemImage: String) -> some View {
        let isSelected = self.selectedSidebarItem == item
        return NavigationLink(value: item) {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                Image(nsImage: SidebarSymbolCache.image(named: systemImage))
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(isSelected ? Color.white.opacity(0.9) : Color.secondary)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)

                Text(title)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
            }
            .font(self.theme.typography.sidebarItem)
            .padding(.vertical, self.theme.metrics.spacing.xs / 2)
        }
        .sidebarOptionHover(
            isSelected: isSelected,
            reduceMotion: self.accessibilityReduceMotion
        )
    }

    private var themePreferenceButton: some View {
        Button {
            self.settings.themePreference = self.nextThemePreference(after: self.settings.themePreference)
        } label: {
            Image(systemName: self.settings.themePreference.systemImageName)
                .fluidToolbarIcon()
        }
        .help("Theme: \(self.settings.themePreference.displayName)")
        .accessibilityLabel("Theme")
    }

    private func nextThemePreference(after preference: SettingsStore.ThemePreference) -> SettingsStore.ThemePreference {
        switch preference {
        case .system: return .light
        case .light: return .dark
        case .dark: return .system
        }
    }

    private var todayStatsButton: some View {
        TodayStatsToolbarButton(typingWPM: self.settings.userTypingWPM) {
            self.navigateToApp(.stats)
        }
    }

    private var detailView: some View {
        ZStack {
            self.theme.palette.contentBackground
                .ignoresSafeArea()

            // Preserve the app destination so Back never waits on expensive detail initialization.
            self.appDetailContent
                .environment(\.fluidPageToolbarVisible, self.pagePresentation.showsPageActions)
                .opacity(self.settingsNavigation.isPresented ? 0 : 1)
                .offset(x: self.settingsNavigation.isPresented ? -6 : 0)
                .allowsHitTesting(!self.settingsNavigation.isPresented)
                .accessibilityHidden(self.settingsNavigation.isPresented)

            if self.settingsNavigation.isPresented {
                self.preferencesView
                    .transition(self.settingsDetailTransition)
            }
        }
        .animation(self.modeTransitionAnimation, value: self.settingsNavigation.isPresented)
        .navigationTitle(self.pagePresentation.title)
    }

    private var pagePresentation: AppPagePresentation {
        AppPagePresentation(destination: self.selectedSidebarItem, settings: self.settingsNavigation)
    }

    private var settingsDetailTransition: AnyTransition {
        if self.accessibilityReduceMotion {
            return .opacity
        }
        return .offset(x: 8).combined(with: .opacity)
    }

    private var appDetailContent: AnyView {
        switch (self.selectedSidebarItem ?? .welcome).shownInThisBuild {
        case .welcome:
            return AnyView(self.welcomeView)
        case .voiceEngine:
            return AnyView(VoiceEngineSettingsScreen(
                appServices: self.appServices,
                theme: self.theme
            ))
        case .aiEnhancements, .cleanupStyles:
            return AnyView(AIEnhancementSettingsScreen(
                menuBarManager: self.menuBarManager,
                theme: self.theme,
                selectedConfigurationSection: self.aiEnhancementConfigurationSectionBinding,
                activeShortcutRecordingTarget: self.$activeShortcutRecordingTarget,
                shortcutRecordingMessage: self.$shortcutRecordingMessage,
                revealTarget: self.$appSearchRevealTarget
            ))
        case .fileTranscription:
            return AnyView(self.fileTranscriptionView)
        case .meetingTranscription:
            return AnyView(self.meetingTranscriptionView)
        case .customDictionary:
            return AnyView(CustomDictionaryView(revealTarget: self.$appSearchRevealTarget))
        case .stats:
            return AnyView(self.statsView)
        case .feedback:
            return AnyView(FeedbackView())
        case .changelog:
            return AnyView(ChangelogView())
        case .commandMode:
            return AnyView(self.commandModeView)
        case .rewriteMode:
            return AnyView(self.rewriteModeView)
        case .history:
            return AnyView(TranscriptionHistoryView())
        }
    }

    private var aiEnhancementConfigurationSectionBinding: Binding<AIEnhancementConfigurationSection> {
        Binding(
            get: {
                self.selectedSidebarItem?.aiEnhancementConfigurationSection ?? .providers
            },
            set: { section in
                guard self.selectedSidebarItem != section.sidebarItem else { return }
                self.navigateToApp(section.sidebarItem)
            }
        )
    }

    private var onboardingOnlyView: some View {
        OnboardingFlowView(
            currentStep: Binding(
                get: { self.settings.onboardingCurrentStep },
                set: { self.settings.onboardingCurrentStep = $0 }
            ),
            accessibilityEnabled: self.accessibilityEnabled,
            accessibilitySetupInProgress: self.didOpenAccessibilityPane,
            markAISkipped: {
                self.settings.onboardingAISkipped = true
                self.settings.setDictationPromptSelection(.off)
            },
            finishOnboarding: {
                self.completeOnboardingIfPossible()
            },
            finishOnboardingAtGettingStarted: {
                self.completeOnboardingIfPossible(selecting: .welcome)
            },
            openAccessibilitySettings: self.openAccessibilitySettings,
            restartApp: self.restartApp,
            menuBarManager: self.menuBarManager,
            activeShortcutRecordingTarget: self.$activeShortcutRecordingTarget,
            shortcutRecordingMessage: self.$shortcutRecordingMessage,
            theme: self.theme
        )
        .environmentObject(self.appServices)
        .ignoresSafeArea(.container, edges: .top)
    }

    // MARK: - Welcome Guide

    private var welcomeView: some View {
        WelcomeView(
            selectedSidebarItem: self.$selectedSidebarItem,
            accessibilityEnabled: self.accessibilityEnabled,
            openAccessibilitySettings: self.openAccessibilitySettings,
            openFluidIntelligenceDemo: { self.showsFluidIntelligenceDemo = true },
            openShortcutSettings: { self.openSettings(.shortcuts) }
        )
    }

    // MARK: - Microphone Permission View (Kept inline for RecordingView)

    private var microphonePermissionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                // Status indicator
                Circle()
                    .fill(self.asr.micStatus == .authorized ? self.theme.palette.success : self.theme.palette.warning)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 4) {
                    Text(self.labelFor(status: self.asr.micStatus))
                        .fontWeight(.medium)
                        .foregroundStyle(self.asr.micStatus == .authorized ? self.theme.palette.primaryText : self.theme.palette.warning)

                    if self.asr.micStatus != .authorized {
                        Text("Microphone access is required for voice recording")
                            .font(self.theme.typography.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()

                self.microphoneActionButton
            }

            // Step-by-step instructions when microphone is not authorized
            if self.asr.micStatus != .authorized {
                self.microphoneInstructionsView
            }
        }
    }

    /// Drawn inside the sidebar rather than as a toolbar item, so no macOS version can
    /// wrap it in its own glass capsule. Sits up in the title bar band, just right of the
    /// traffic lights, well clear of the detail toolbar's glass group.
    /// Same height, font and corner as the section rows below it, so it reads as part of the list.
    private var settingsSearchRow: some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.fluidSystem(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
            TextField("Search Settings", text: Binding(
                get: { self.settingsSearchQuery },
                set: { self.updateSettingsSearchQuery($0) }
            ))
            .textFieldStyle(.plain)
            .font(self.theme.typography.sidebarItem)
            .focused(self.$isSettingsSearchFocused)
            if !self.settingsSearchQuery.isEmpty {
                Button {
                    self.updateSettingsSearchQuery("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.fluidSystem(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(self.isSettingsSearchFocused ? 0.10 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(self.theme.palette.accent.opacity(self.isSettingsSearchFocused ? 0.5 : 0), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.12), value: self.isSettingsSearchFocused)
        .onChange(of: self.settingsNavigation.isPresented) { _, presented in
            if !presented { self.isSettingsSearchFocused = false }
        }
        .accessibilityLabel("Search Settings")
    }

    private func toggleSidebar() {
        withAnimation(self.accessibilityReduceMotion ? nil : .easeInOut(duration: 0.2)) {
            self.columnVisibility = self.columnVisibility == .detailOnly ? .all : .detailOnly
        }
    }

    private var windowSizing: FluidWindowSizing {
        let window = self.theme.metrics.window
        if self.settings.shouldShowOnboarding {
            return .minimum(width: window.onboardingMinWidth, height: window.onboardingMinHeight)
        }
        // Let SwiftUI and the screen choose the upper size; a hard cap can
        // fight the hosting view's content bounds while switching pages.
        return .minimum(width: window.mainMinWidth, height: window.mainMinHeight)
    }

    @ViewBuilder
    private func applyMainWindowToolbar<Content: View>(to content: Content) -> some View {
        if self.settings.shouldShowOnboarding {
            content
        } else {
            content
                .toolbar {
                    // Keep one navigation control alive in both sidebar states. An overlay
                    // belongs to the sidebar content and shifts below AppKit-hosted title bars.
                    ToolbarItem(placement: .navigation) {
                        Button(action: self.toggleSidebar) {
                            Image(systemName: "sidebar.left")
                                .fluidToolbarIcon()
                        }
                        .buttonStyle(.automatic)
                        .help(self.columnVisibility == .detailOnly ? "Show sidebar" : "Hide sidebar")
                        .accessibilityLabel(self.columnVisibility == .detailOnly ? "Show sidebar" : "Hide sidebar")
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        UpdateAvailableToolbarButton()

                        self.todayStatsButton
                            .buttonStyle(.automatic)

                        self.themePreferenceButton
                            .buttonStyle(.automatic)

                        Button(action: self.openIssueReportingPage) {
                            Image(systemName: "ladybug.fill")
                                .fluidToolbarIcon()
                        }
                        .buttonStyle(.automatic)
                        .help("Report an issue")
                        .accessibilityLabel("Report an issue")
                    }
                    if !self.hasPageToolbarActions {
                        FluidToolbarEdgeSpace(width: self.toolbarTrailingInset)
                    }
                }
                .toolbar(removing: .sidebarToggle)
        }
    }

    private var hasPageToolbarActions: Bool {
        guard !self.settingsNavigation.isPresented else { return false }
        return switch self.selectedSidebarItem ?? .welcome {
        case .stats, .commandMode, .meetingTranscription, .customDictionary, .changelog: true
        default: false
        }
    }

    private var microphoneActionButton: some View {
        Group {
            if self.asr.micStatus == .notDetermined {
                Button {
                    self.asr.requestMicAccess()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                        Text("Grant Access")
                            .fontWeight(.medium)
                    }
                }
                .buttonStyle(GlassButtonStyle())
                .buttonHoverEffect()
            } else if self.asr.micStatus == .denied {
                Button {
                    self.asr.openSystemSettingsForMic()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "gear")
                        Text("Open Settings")
                            .fontWeight(.medium)
                    }
                }
                .buttonStyle(GlassButtonStyle())
                .buttonHoverEffect()
            }
        }
    }

    private var microphoneInstructionsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(self.theme.palette.accent)
                    .font(self.theme.typography.caption)
                Text("How to enable microphone access:")
                    .font(self.theme.typography.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                if self.asr.micStatus == .notDetermined {
                    self.instructionStep(number: "1", text: "Click **Grant Access** above")
                    self.instructionStep(number: "2", text: "Choose **Allow** in the system dialog")
                } else if self.asr.micStatus == .denied {
                    self.instructionStep(number: "1", text: "Click **Open Settings** above")
                    self.instructionStep(number: "2", text: "Find **FluidVoice** in the microphone list")
                    self.instructionStep(number: "3", text: "Toggle **FluidVoice ON** to allow access")
                }
            }
            .padding(.leading, 4)
        }
        .padding(12)
        .background(self.theme.palette.accent.opacity(0.12))
        .cornerRadius(8)
    }

    private func instructionStep(number: String, text: String) -> some View {
        HStack(spacing: 8) {
            Text(number + ".")
                .font(self.theme.typography.captionSmall)
                .foregroundStyle(self.theme.palette.accent)
                .fontWeight(.semibold)
                .frame(width: 16)
            Text(text)
                .font(self.theme.typography.caption)
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Preferences View

    @ViewBuilder
    private var preferencesView: some View {
        if self.isSettingsSearchActive, self.settingsSearchResults.isEmpty {
            ContentUnavailableView {
                Label("No Settings Found", systemImage: "magnifyingglass")
            } description: {
                Text("No settings match “\(self.settingsSearchQuery)”.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        } else {
            SettingsView(
                selectedSection: self.settingsNavigation.selectedSection ?? .general,
                searchResults: self.settingsSearchResults,
                searchScrollRequest: self.settingsSearchScrollRequest,
                microphonePreferenceCoordinator: self.appServices.microphonePreferenceCoordinator,
                appear: self.$appear,
                visualizerNoiseThreshold: self.$settings.visualizerNoiseThreshold,
                selectedInputUID: self.$selectedInputUID,
                selectedOutputUID: self.$selectedOutputUID,
                inputDevices: self.$inputDevices,
                outputDevices: self.$outputDevices,
                accessibilityEnabled: self.$accessibilityEnabled,
                primaryDictationShortcuts: self.$settings.primaryDictationShortcuts,
                activeShortcutRecordingTarget: self.$activeShortcutRecordingTarget,
                shortcutRecordingMessage: self.$shortcutRecordingMessage,
                commandModeShortcut: self.$settings.commandModeHotkeyShortcut,
                rewriteShortcut: self.$settings.rewriteModeHotkeyShortcut,
                cancelRecordingShortcut: self.$settings.cancelRecordingHotkeyShortcut,
                pasteLastTranscriptionShortcut: self.$settings.pasteLastTranscriptionHotkeyShortcut,
                commandModeShortcutEnabled: self.commandModeShortcutEnabledBinding,
                rewriteShortcutEnabled: self.$settings.rewriteModeShortcutEnabled,
                pasteLastTranscriptionShortcutEnabled: self.$settings.pasteLastTranscriptionShortcutEnabled,
                hotkeyManagerInitialized: self.$hotkeyManagerInitialized,
                hotkeyMode: self.$settings.hotkeyMode,
                enableStreamingPreview: self.$settings.enableStreamingPreview,
                copyToClipboard: self.$settings.copyTranscriptionToClipboard,
                hotkeyManager: self.hotkeyManager,
                menuBarManager: self.menuBarManager,
                startRecording: { _ = self.session.startRecording() },
                refreshDevices: self.refreshDevices,
                openAccessibilitySettings: self.openAccessibilitySettings,
                restartApp: self.restartApp,
                revealAppInFinder: self.revealAppInFinder,
                openApplicationsFolder: self.openApplicationsFolder
            )
        }
    }

    private var recordingView: some View {
        RecordingView(
            appear: self.$appear,
            stopAndProcessTranscription: { await self.session.stopAndProcessTranscription() },
            startRecording: { _ = self.session.startRecording() }
        )
    }

    private var commandModeView: some View {
        CommandModeView(
            service: self.commandModeService,
            isActive: !self.settingsNavigation.isPresented,
            onClose: {
                self.navigateToApp(.welcome)
            }
        )
    }

    private var rewriteModeView: some View {
        RewriteModeView(service: self.rewriteModeService, onClose: {
            self.navigateToApp(.welcome)
        })
    }

    // MARK: - File and Meeting Transcription

    private var fileTranscriptionView: some View {
        FileTranscriptionView(
            asrService: self.asr,
            transcriptionService: self.appServices.fileTranscriptionService,
            revealTarget: self.$appSearchRevealTarget
        )
    }

    private var meetingTranscriptionView: some View {
        MeetingTranscriptionView(
            coordinator: self.appServices.meetingSessionCoordinator,
            asrService: self.asr,
            historySnapshot: self.meetingHistorySnapshot,
            onOpenVoiceEngine: { self.selectedSidebarItem = .voiceEngine }
        )
    }

    // MARK: - Stats View

    private var statsView: some View {
        StatsView()
    }

    // Audio settings merged into SettingsView

    private func refreshDevices() {
        // Query CoreAudio off the main thread — during device topology changes, synchronous
        // CoreAudio calls on main can deadlock while the HAL is still settling.
        DispatchQueue.global(qos: .userInitiated).async {
            let inputs = AudioDevice.listInputDevicesRefreshingLiveness()
            let outputs = AudioDevice.listOutputDevices()
            let defaultInputUID = AudioDevice.getDefaultInputDevice()?.uid
            DispatchQueue.main.async {
                self.inputDevices = inputs
                self.outputDevices = outputs
                if let selectedInput = self.appServices.microphonePreferenceCoordinator
                    .reconcileMicrophoneSelection(
                        availableInputs: inputs,
                        defaultInputUID: defaultInputUID
                    )
                {
                    self.selectedInputUID = selectedInput.uid
                }
            }
        }
    }

    private func refreshInputDevices() {
        DispatchQueue.global(qos: .userInitiated).async {
            let inputs = AudioDevice.listInputDevicesRefreshingLiveness()
            let defaultInputUID = AudioDevice.getDefaultInputDevice()?.uid
            DispatchQueue.main.async {
                self.inputDevices = inputs
                if let selectedInput = self.appServices.microphonePreferenceCoordinator
                    .reconcileMicrophoneSelection(
                        availableInputs: inputs,
                        defaultInputUID: defaultInputUID
                    )
                {
                    self.selectedInputUID = selectedInput.uid
                }
            }
        }
    }

    // MARK: - Commented out app-specific prompts - using general processing only

    /*
     private func getContextualPrompt(for appInfo: (name: String, bundleId: String, windowTitle: String)) -> String {
         let appName = appInfo.name
         let bundleId = appInfo.bundleId.lowercased()
         let windowTitle = appInfo.windowTitle.lowercased()

         // Code editors and IDEs
         if bundleId.contains("xcode") || bundleId.contains("vscode") || bundleId.contains("sublime") ||
            bundleId.contains("atom") || bundleId.contains("jetbrains") || bundleId.contains("cursor") ||
            bundleId.contains("vim") || bundleId.contains("emacs") || appName.lowercased().contains("code")
         {
             return "Clean up this transcribed text for code editor \(appName). Make the smallest necessary mechanical edits; do not add or invent content or answer questions. Remove fillers and false starts. Correct programming terms and obvious transcription errors. Preserve meaning and tone."
         }

         // Email applications
         else if bundleId.contains("mail") || bundleId.contains("outlook") || bundleId.contains("thunderbird") ||
                 bundleId.contains("airmail") || bundleId.contains("spark")
         {
             return "Clean up this transcribed text for email app \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix grammar, punctuation, and capitalization while preserving meaning and tone."
         }

         // Messaging and chat applications
         else if bundleId.contains("messages") || bundleId.contains("slack") || bundleId.contains("discord") ||
                 bundleId.contains("telegram") || bundleId.contains("whatsapp") || bundleId.contains("signal") ||
                 bundleId.contains("teams") || bundleId.contains("zoom")
         {
             return "Clean up this transcribed text for messaging app \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix basic grammar and clarity while keeping the casual tone."
         }

         // Document editors and word processors
         else if bundleId.contains("pages") || bundleId.contains("word") || bundleId.contains("docs") ||
                 bundleId.contains("writer") || bundleId.contains("notion") || bundleId.contains("bear") ||
                 bundleId.contains("ulysses") || bundleId.contains("scrivener")
         {
             return "Clean up this transcribed text for document editor \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix grammar, punctuation, and structure while preserving meaning."
         }

         // Note-taking applications
         else if bundleId.contains("notes") || bundleId.contains("obsidian") || bundleId.contains("roam") ||
                 bundleId.contains("logseq") || bundleId.contains("evernote") || bundleId.contains("onenote")
         {
             return "Clean up this transcribed text for note-taking app \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix grammar and organize into clear, readable notes without adding information."
         }

         // Browsers (various web apps). Include: Safari, Chrome, Firefox, Edge, Arc, Brave, Dia, Comet
         else if bundleId.contains("safari") || bundleId.contains("chrome") || bundleId.contains("firefox") ||
                 bundleId.contains("edge") || bundleId.contains("arc") || bundleId.contains("brave") ||
                 bundleId.contains("dia") || bundleId.contains("comet") ||
                 appName.lowercased().contains("safari") || appName.lowercased().contains("chrome") ||
                 appName.lowercased().contains("arc") || appName.lowercased().contains("brave") ||
                 appName.lowercased().contains("dia") || appName.lowercased().contains("comet")
         {
             // Infer common web apps from window title for better context
             if let inferred = inferWebContext(from: windowTitle, appName: appName) {
                 return inferred
             }
             return "Clean up this transcribed text for web browser \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix grammar and basic formatting while preserving meaning."
         }

         // Terminal and command line tools
         else if bundleId.contains("terminal") || bundleId.contains("iterm") || bundleId.contains("console") ||
                 appName.lowercased().contains("terminal")
         {
             return "Clean up this transcribed text for terminal \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix command syntax, file paths, and technical terms without adding options or commands."
         }

         // Social media and creative apps
         else if bundleId.contains("twitter") || bundleId.contains("facebook") || bundleId.contains("instagram") ||
                 bundleId.contains("tiktok") || bundleId.contains("linkedin")
         {
             return "Clean up this transcribed text for social media app \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix basic grammar while keeping the natural, engaging tone."
         }

         // Default fallback
         else
         {
             return "Clean up this transcribed text for \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix grammar, punctuation, and formatting while preserving meaning and tone."
         }
     }
     */

    /*
     /// Infer web-app specific prompt from a browser window title
     private func inferWebContext(from windowTitle: String, appName: String) -> String? {
         let title = windowTitle
         // Email (Gmail, Outlook Web)
         if title.contains("gmail") || title.contains("inbox") || title.contains("outlook") {
             return "Clean up this transcribed text for email app \(appName) (web). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix grammar, punctuation, and capitalization while preserving meaning."
         }
         // Messaging (Slack, Discord, Teams, Telegram, WhatsApp)
         if title.contains("slack") || title.contains("discord") || title.contains("teams") || title.contains("telegram") || title.contains("whatsapp") {
             return "Clean up this transcribed text for messaging app \(appName) (web). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Fix basic grammar and clarity while keeping the casual tone."
         }
         // Documents (Google Docs/Sheets, Notion, Confluence)
         if title.contains("google docs") || title.contains("docs") || title.contains("notion") || title.contains("confluence") || title.contains("google sheets") || title.contains("sheet") {
             return "Clean up this transcribed text for a document editor in \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Improve grammar, structure, and readability without adding information."
         }
         // Code (GitHub, Stack Overflow, online IDEs)
         if title.contains("github") || title.contains("stack overflow") || title.contains("stackexchange") || title.contains("replit") || title.contains("codesandbox") {
             return "Clean up this transcribed text for code-related context in \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Correct programming terms and obvious errors without adding explanations."
         }
         // Project/issue tracking (Jira, Linear, Asana)
         if title.contains("jira") || title.contains("linear") || title.contains("asana") || title.contains("clickup") {
             return "Clean up this transcribed text for project management context in \(appName). Make minimal edits only; do not add or invent content or answer questions. Remove fillers and false starts. Keep the text concise and clear without adding commentary."
         }
         return nil
     }
     */

    // NOTE: Thinking token filtering is now handled by LLMClient.stripThinkingTags()

    // MARK: - Modular AI Processing

    // MARK: - Streaming Response Handler (DEPRECATED - Now handled by LLMClient)

    // This method is no longer used - LLMClient.call() handles streaming internally

    // MARK: - ASR Model Management

    /// Manual download trigger - downloads models when user clicks button
    private func downloadModels() async {
        DebugLogger.shared.debug("User initiated model download", source: "ContentView")

        do {
            try await self.asr.ensureAsrReady()
            DebugLogger.shared.info("Model download completed successfully", source: "ContentView")
        } catch {
            DebugLogger.shared.error("Failed to download models: \(error)", source: "ContentView")
        }
    }

    /// Delete models from disk
    private func deleteModels() async {
        DebugLogger.shared.debug("User initiated model deletion", source: "ContentView")

        do {
            try await self.asr.clearModelCache()
            DebugLogger.shared.info("Models deleted successfully", source: "ContentView")
        } catch {
            DebugLogger.shared.error("Failed to delete models: \(error)", source: "ContentView")
        }
    }

    // MARK: - ASR Model Preloading

    private func preloadASRModel() async {
        // DEPRECATED: No longer auto-loads on startup - models downloaded manually
        DebugLogger.shared.debug("Skipping auto-preload - models downloaded manually via UI", source: "ContentView")
    }

    private func initializeHotkeyManagerIfNeeded() {
        NotchContentState.shared.onPromptModeSwitchRequested = { mode in
            self.session.handleLivePromptModeSwitch(mode)
        }
        NotchContentState.shared.onOverlayModeSwitchRequested = { mode in
            self.session.handleLiveOverlayModeSwitch(mode)
        }
        NotchContentState.shared.onReprocessLastRequested = {
            self.session.reprocessLastDictation()
        }
        NotchContentState.shared.onCopyLastRequested = {
            self.session.copyLastDictationFromHistory()
        }
        PasteOutcomeCenter.shared.pasteLastHandler = {
            await self.session.pasteLastDictationFromHistory()
        }
        NotchContentState.shared.onPasteLastRequested = {
            Task { @MainActor in _ = await PasteOutcomeCenter.shared.pasteLastTranscript() }
        }
        NotchContentState.shared.onRetryTextDeliveryRequested = { transcript in
            Task { @MainActor in
                await self.session.retryTextDelivery(transcript)
            }
        }
        NotchContentState.shared.onUndoLastAIRequested = {
            self.session.undoLastAIProcessingFromHistory()
        }
        NotchContentState.shared.onOpenPreferencesRequested = {
            self.menuBarManager.openPreferencesFromUI()
        }
        NotchContentState.shared.onCancelRequested = {
            _ = self.handleCancelShortcut()
        }
        NotchContentState.shared.onDictationPromptSelectionRequested = { selection in
            guard selection != .privateAI || PrivateAIProviderPromptFormat.isAvailable() else { return }
            let slot = self.session.activeDictationShortcutSlot ?? .primary
            DictationAppSession.shared.select(selection, slot: slot, appID: DictationAppSession.shared.appID)
            self.session.applyDictationShortcutSelectionContext(for: slot)
            self.session.prewarmDictationCleanupIfNeeded(for: slot)
        }

        guard self.hotkeyManager == nil else { return }

        self.hotkeyManager = GlobalHotkeyManager(
            asrService: self.asr,
            primaryShortcuts: self.primaryDictationShortcuts,
            promptModeShortcut: self.promptModeHotkeyShortcut,
            commandModeShortcut: self.commandModeHotkeyShortcut,
            rewriteModeShortcut: self.rewriteModeHotkeyShortcut,
            promptShortcutAssignments: SettingsStore.shared.dictationPromptShortcutAssignments(),
            promptModeShortcutEnabled: self.isPromptModeShortcutEnabled,
            commandModeShortcutEnabled: self.isCommandModeShortcutEnabled,
            rewriteModeShortcutEnabled: self.isRewriteModeShortcutEnabled,
            startRecordingCallback: {
                DebugLogger.shared.debug("ContentView: startRecordingCallback invoked by hotkey", source: "ContentView")
                await self.session.awaitCaptureStart(self.session.startRecording())
            },
            dictationModeCallback: {
                DebugLogger.shared.info("Dictate mode triggered", source: "ContentView")
                DebugLogger.shared.debug(
                    "ContentView: selected model for dictate hotkey=\(SettingsStore.shared.selectedSpeechModel.displayName)",
                    source: "ContentView"
                )
                await self.session.awaitCaptureStart(self.session.beginDictationRecording(for: .primary, mode: .dictate))
            },
            stopAndProcessCallback: { toggleStopRequestedAt in
                let route = self.session.currentDictationOutputRouteForHotkeyStop()
                DebugLogger.shared.info("Hotkey stop callback using route: \(route.rawValue)", source: "ContentView")
                await self.session.stopAndProcessTranscription(
                    route: route,
                    toggleStopRequestedAt: toggleStopRequestedAt
                )
            },
            promptModeCallback: {
                DebugLogger.shared.info("Prompt mode triggered", source: "ContentView")
                await self.session.awaitCaptureStart(self.session.beginDictationRecording(for: .secondary, mode: .promptMode))
            },
            promptSelectionCallback: { selection in
                DebugLogger.shared.info("Prompt selection shortcut triggered", source: "ContentView")
                await self.session.awaitCaptureStart(self.session.beginDictationRecording(for: selection, mode: .promptMode))
            },
            commandModeCallback: {
                guard !self.session.presentExclusiveActivityBlockIfNeeded() else { return }
                DebugLogger.shared.info("Command mode triggered", source: "ContentView")
                self.session.captureRecordingContext()

                // Set flag so stopAndProcessTranscription knows to process as command
                self.session.setActiveRecordingMode(.command)

                // Set overlay mode to command
                self.menuBarManager.setOverlayMode(.command)

                guard !self.asr.isRunningOrStarting else { return }

                self.session.advanceOverlayLifecycle()

                // Start recording immediately for the command
                DebugLogger.shared.info(
                    "Starting voice recording for command",
                    source: "ContentView"
                )
                let captureOverlayLifecycleID = self.session.overlayLifecycleID
                let captureTask = Task {
                    guard !Task.isCancelled else {
                        self.session.clearCancelledCaptureStart(lifecycleID: captureOverlayLifecycleID, mode: .command)
                        return
                    }
                    let startOutcome = await self.asr.start(onCaptureStarted: {
                        TranscriptionSoundPlayer.shared.playStartSound()
                        self.appBench("overlay_phase phase=recording trigger=first_pcm mode=command")
                    })
                    guard !Task.isCancelled else {
                        self.session.clearCancelledCaptureStart(lifecycleID: captureOverlayLifecycleID, mode: .command)
                        return
                    }
                    if startOutcome == .failed {
                        self.menuBarManager.hideRecordingOverlayImmediately(
                            reason: "command_asr_start_failed"
                        )
                    }
                }
                await self.session.awaitCaptureStart(captureTask)
            },
            rewriteModeCallback: {
                guard !self.session.presentExclusiveActivityBlockIfNeeded() else { return }

                self.session.captureRecordingContext()

                // Try to capture text first while still in the other app
                let captured = self.rewriteModeService.captureSelectedText()
                DebugLogger.shared.info("Rewrite mode triggered, text captured: \(captured)", source: "ContentView")

                if !captured {
                    // No text selected - start in "write mode" where user speaks
                    // what to write
                    DebugLogger.shared
                        .info(
                            "No text selected - starting in write/improve mode",
                            source: "ContentView"
                        )
                    self.rewriteModeService.startWithoutSelection()
                    // Set overlay mode to edit
                    self.menuBarManager.setOverlayMode(.edit)
                } else {
                    // Text was selected - edit mode (with selected context)
                    self.menuBarManager.setOverlayMode(.edit)
                }

                // Set flag so stopAndProcessTranscription knows to process as rewrite
                self.session.setActiveRecordingMode(.edit)

                guard !self.asr.isRunningOrStarting else { return }

                self.session.advanceOverlayLifecycle()

                // Start recording immediately for the edit instruction
                DebugLogger.shared.info("Starting voice recording for edit mode", source: "ContentView")
                let captureOverlayLifecycleID = self.session.overlayLifecycleID
                let captureTask = Task {
                    guard !Task.isCancelled else {
                        self.session.clearCancelledCaptureStart(lifecycleID: captureOverlayLifecycleID, mode: .edit)
                        return
                    }
                    let startOutcome = await self.asr.start(onCaptureStarted: {
                        TranscriptionSoundPlayer.shared.playStartSound()
                        self.appBench("overlay_phase phase=recording trigger=first_pcm mode=edit")
                    })
                    guard !Task.isCancelled else {
                        self.session.clearCancelledCaptureStart(lifecycleID: captureOverlayLifecycleID, mode: .edit)
                        return
                    }
                    if startOutcome == .failed {
                        self.menuBarManager.hideRecordingOverlayImmediately(
                            reason: "edit_asr_start_failed"
                        )
                    }
                }
                await self.session.awaitCaptureStart(captureTask)
            },
            isDictateRecordingProvider: {
                self.session.activeRecordingMode == .dictate
            },
            isPromptModeRecordingProvider: {
                self.session.activeRecordingMode == .promptMode
            },
            isCommandRecordingProvider: {
                self.session.activeRecordingMode == .command
            },
            isRewriteRecordingProvider: {
                self.session.activeRecordingMode == .edit
            },
            isShortcutCaptureActiveProvider: {
                self.isRecordingAnyShortcutCapture
            },
            shortcutCaptureHandler: {
                self.handleShortcutCaptureEvent($0)
            }
        )
        if let hotkeyManager = self.hotkeyManager {
            HotkeyManagerOwner.shared.install(hotkeyManager)
        }
        self.hotkeyManager?.registerDebugToggleTriggerIfEnabled()

        self.hotkeyManagerInitialized = self.hotkeyManager?.validateEventTapHealth() ?? false

        self.hotkeyManager?.setHotkeyMode(self.hotkeyMode)

        // Set cancel callback for Escape key handling (closes transient UI, resets recording state)
        // Distinguishes suggestion dismissal from recording cancellation.
        self.hotkeyManager?.setCancelCallback {
            self.handleCancelShortcutResult()
        }

        // Re-insert the most recent transcription on demand (no clipboard involved).
        self.hotkeyManager?.setPasteLastTranscriptionCallback {
            Task { @MainActor in _ = await PasteOutcomeCenter.shared.pasteLastTranscript() }
        }

        // Monitor initialization status
        Task {
            // Give some time for initialization
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds

            await MainActor.run {
                self.hotkeyManagerInitialized = self.hotkeyManager?.validateEventTapHealth() ?? false
                DebugLogger.shared.debug("Initial hotkey manager health check: \(self.hotkeyManagerInitialized)", source: "ContentView")

                // If still not initialized and accessibility is enabled, try reinitializing
                if !self.hotkeyManagerInitialized && self.accessibilityEnabled {
                    self.hotkeyManagerInitialized = self.hotkeyManager?.validateEventTapHealth() ?? false
                    DebugLogger.shared.debug("Initial hotkey manager health check: \(self.hotkeyManagerInitialized)", source: "ContentView")

                    // If still not initialized and accessibility is enabled, try reinitializing
                    if !self.hotkeyManagerInitialized && self.accessibilityEnabled {
                        DebugLogger.shared.debug("Hotkey manager not healthy, attempting reinitalization", source: "ContentView")
                        self.hotkeyManager?.reinitialize()
                    }
                }
            }
        }
    }

    @discardableResult
    private func handleCancelShortcut() -> Bool {
        self.handleCancelShortcutResult() != .unhandled
    }

    private func handleCancelShortcutResult() -> GlobalHotkeyManager.CancelHandlingResult {
        if self.session.isSavingCancelledRecording { return .cancelled }
        var handled = false

        if DictionaryCorrectionOverlayController.shared.isPresented {
            DictionaryCorrectionOverlayController.shared.dismiss()
            return .dismissedOverlay
        }
        if NotchOverlayManager.shared.isCommandOutputExpanded {
            NotchOverlayManager.shared.hideExpandedCommandOutput()
            NotchOverlayManager.shared.onCommandOutputDismiss?()
            handled = true
        }

        if let lifecycleID = self.session.pendingVoiceCommandLifecycleID {
            self.session.cancelledOutputLifecycleID = lifecycleID
            self.session.pendingVoiceCommandLifecycleID = nil
            handled = self.commandModeService.cancelInvalidPendingCommand() || handled
        }

        if let lifecycleID = self.session.processingDictationLifecycleID {
            // A stop already owns the audio; suppress its pending output without stopping again.
            self.session.cancelledOutputLifecycleID = lifecycleID
            handled = true
        } else if self.asr.isRunningOrStarting {
            let preservesHistory = self.settings.saveTranscriptionHistory && self.asr.isRunning && !self.asr.isDictionaryTrainingCaptureActive
                && (self.session.activeRecordingMode == .dictate || self.session.activeRecordingMode == .promptMode)
                && !self.session.isRecordingForRewrite && !self.session.isRecordingForCommand
                && self.session.currentDictationOutputRouteForHotkeyStop() != .onboardingSandbox
                && !DictationPromptTestCoordinator.shared.isActive && !self.showsFluidIntelligenceDemo
            if preservesHistory {
                self.session.isSavingCancelledRecording = true
                self.session.cancelledOutputLifecycleID = self.session.overlayLifecycleID
                let manager = self.hotkeyManager
                let stopLockStartedAt = manager?.traceStopLocked()
                Task {
                    defer {
                        self.session.isSavingCancelledRecording = false
                        if let stopLockStartedAt { manager?.traceStopUnlocked(since: stopLockStartedAt) }
                    }
                    await self.session.stopAndProcessTranscription(route: .historyOnly)
                }
            } else {
                let isOnboardingTryout = self.session.isOnboardingVoicePlaygroundStepActive
                Task {
                    await self.asr.stopWithoutTranscription()
                    if isOnboardingTryout {
                        AnalyticsService.shared.recordOnboardingTryoutAttemptResult(outcome: .cancelled)
                    }
                }
                if self.session.activeRecordingMode == .edit || self.session.isRecordingForRewrite {
                    self.rewriteModeService.clearState()
                }
                self.session.clearActiveRecordingMode()
            }
            self.session.cancelPrewarmDictationIfNeeded()
            handled = true
        } else if self.session.activeRecordingMode != .none {
            self.session.cancelPrewarmDictationIfNeeded()
            self.session.clearActiveRecordingMode()
            handled = true
        }

        if handled || NotchOverlayManager.shared.isBottomOverlayVisible || NotchOverlayManager.shared.isOverlayVisible {
            self.menuBarManager.beginProcessingCompletionAndHideOverlay()
            handled = true
        }
        if self.selectedSidebarItem == .rewriteMode {
            self.navigateToApp(.welcome)
            handled = true
        }
        if handled {
            self.session.spokenSendAutoStopTask?.cancel()
            self.session.spokenSendAutoStopTask = nil
            self.session.stopSpokenSendVoiceActivityMonitoring()
            self.session.spokenSendCountdownStartedAt = nil
            self.hotkeyManager?.resetModifierOnlyShortcutTracking(reason: .cancel)
        }
        return handled ? .cancelled : .unhandled
    }

    // Deprecated: hotkey persistence is handled via SettingsStore
}

// SidebarItem enum moved to top of file

// AudioDevice and AudioHardwareObserver moved to Services/AudioDeviceService.swift

// MARK: - ContentView Playground & Onboarding Helpers

extension ContentView {

    private func appBench(_ message: @autoclosure () -> String) {
        DebugLogger.shared.benchmark("APP_BENCH", message: message(), source: "AppBenchmark")
    }

    private func callOpenAIChat() async {
        guard !self.isCallingAI else { return }
        await MainActor.run { self.isCallingAI = true }
        defer { Task { await MainActor.run { isCallingAI = false } } }

        do {
            let result = try await self.session.processTextWithAI(aiInputText)
            await MainActor.run { self.aiOutputText = result }
        } catch {
            DebugLogger.shared.error("callOpenAIChat failed: \(error.localizedDescription)", source: "ContentView")
            await MainActor.run { self.aiOutputText = "Error: \(error.localizedDescription)" }
        }
    }

    private func getModelStatusText() -> String {
        if self.asr.isLoadingModel {
            return "Loading model into memory... (30-60 sec)"
        } else if self.asr.isDownloadingModel {
            return "Downloading model... Please wait."
        } else if self.asr.isAsrReady {
            return "Model is ready to use!"
        } else if self.asr.modelsExistOnDisk {
            return "Model cached. Will load on first use."
        } else {
            return "Model will download when needed."
        }
    }

    private var onboardingVoiceModelReady: Bool {
        self.asr.isAsrReady
    }

    private var onboardingMicrophoneReady: Bool {
        self.asr.micStatus == .authorized
    }

    private var onboardingAccessibilityReady: Bool {
        self.accessibilityEnabled
    }

    private var onboardingAIReady: Bool {
        self.settings.onboardingAISkipped || DictationAIPostProcessingGate.isOnboardingChoiceConfigured()
    }

    private var onboardingPlaygroundReady: Bool {
        self.settings.onboardingPlaygroundValidated || self.settings.onboardingPlaygroundSkipped
    }

    @MainActor
    private func revealAppInFinder() {
        let appPath = Bundle.main.bundlePath
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: appPath)])
    }

    private func openApplicationsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
    }
}

// MARK: - ContentView Accessibility & Lifecycle Helpers

extension ContentView {
    func completeOnboardingIfPossible(selecting target: SidebarItem? = nil) {
        let missingRequirements = self.missingOnboardingCompletionRequirements()
        guard missingRequirements.isEmpty else {
            self.presentOnboardingCompletionBlocked(missingRequirements)
            return
        }

        self.completeOnboarding(selecting: target)
    }

    private func completeOnboarding(selecting target: SidebarItem? = nil) {
        self.settings.onboardingCompleted = true
        self.navigateToApp(target ?? .welcome)
    }

    private func missingOnboardingCompletionRequirements() -> [String] {
        var missing: [String] = []

        if !self.onboardingVoiceModelReady {
            missing.append("voice model")
        }
        if !self.onboardingMicrophoneReady {
            missing.append("microphone access")
        }
        if !self.onboardingAccessibilityReady {
            missing.append("Accessibility access")
        }
        if !self.onboardingAIReady {
            missing.append("AI choice")
        }
        if !self.onboardingPlaygroundReady {
            missing.append("test or skip")
        }

        return missing
    }

    private func presentOnboardingCompletionBlocked(_ missingRequirements: [String]) {
        let missingText = missingRequirements.joined(separator: ", ")
        DebugLogger.shared.warning(
            "Onboarding completion blocked; missing=\(missingText)",
            source: "ContentView"
        )
        self.asr.errorTitle = "Setup Isn't Complete"
        self.asr.errorMessage = "Finish \(missingText) to continue."
        self.asr.showError = true
    }

    func labelFor(status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "Microphone: Authorized"
        case .denied: return "Microphone: Denied"
        case .restricted: return "Microphone: Restricted"
        case .notDetermined: return "Microphone: Not Determined"
        @unknown default: return "Microphone: Unknown"
        }
    }

    func checkAccessibilityPermissions() -> Bool {
        return AXIsProcessTrusted()
    }

    @discardableResult
    private func refreshAccessibilityPermissionState() -> Bool {
        let trusted = self.checkAccessibilityPermissions()
        let newlyGranted = trusted && !self.accessibilityEnabled
        if trusted != self.accessibilityEnabled {
            self.accessibilityEnabled = trusted
        }
        if newlyGranted,
           UserDefaults.standard.bool(forKey: self.accessibilityRestartFlagKey),
           !UserDefaults.standard.bool(forKey: self.hasAutoRestartedForAccessibilityKey)
        {
            UserDefaults.standard.set(true, forKey: self.hasAutoRestartedForAccessibilityKey)
            DebugLogger.shared.info("Auto-restarting app after accessibility grant", source: "ContentView")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.restartApp()
            }
        }
        return trusted
    }

    func openAccessibilitySettings() {
        let requestID = UUID()
        self.accessibilityGuideRequestID = requestID

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        self.didOpenAccessibilityPane = true
        UserDefaults.standard.set(true, forKey: self.accessibilityRestartFlagKey)
        self.startAccessibilityPolling()
        self.positionWindowBesideSystemSettings(requestID: requestID)
        self.showAccessibilityGuidePanel(requestID: requestID)
        self.activateSystemSettingsSoon(requestID: requestID)
    }

    private func positionWindowBesideSystemSettings(requestID: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard self.accessibilityGuideRequestID == requestID else { return }
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "FluidVoice" }) ?? NSApp.keyWindow else {
                return
            }

            let screen = self.systemSettingsWindowFrame()
                .flatMap { settingsFrame in
                    NSScreen.screens.first { $0.frame.intersects(settingsFrame) }
                } ?? window.screen ?? NSScreen.main
            guard let screen else { return }

            let visibleFrame = screen.visibleFrame
            let currentSize = window.frame.size
            let guideWidth = min(currentSize.width, max(640, visibleFrame.width * 0.42))
            let guideHeight = min(currentSize.height, visibleFrame.height - 56)
            let targetSize = NSSize(width: guideWidth, height: guideHeight)

            let settingsFrame = self.systemSettingsWindowFrame()
            let gap: CGFloat = 20
            let targetX: CGFloat
            if let settingsFrame, settingsFrame.maxX + gap + targetSize.width <= visibleFrame.maxX {
                targetX = settingsFrame.maxX + gap
            } else if let settingsFrame, settingsFrame.minX - gap - targetSize.width >= visibleFrame.minX {
                targetX = settingsFrame.minX - gap - targetSize.width
            } else {
                targetX = visibleFrame.maxX - targetSize.width - 24
            }

            let targetY: CGFloat
            if let settingsFrame {
                targetY = min(
                    visibleFrame.maxY - targetSize.height - 16,
                    max(visibleFrame.minY + 16, settingsFrame.maxY - targetSize.height)
                )
            } else {
                targetY = visibleFrame.midY - (targetSize.height / 2)
            }

            window.setFrame(
                NSRect(origin: NSPoint(x: targetX, y: targetY), size: targetSize),
                display: true,
                animate: true
            )
            window.orderBack(nil)
        }
    }

    private func systemSettingsWindowFrame() -> NSRect? {
        guard let windowList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for info in windowList {
            guard (info[kCGWindowOwnerName as String] as? String) == "System Settings",
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let x = bounds["X"] as? CGFloat,
                  let y = bounds["Y"] as? CGFloat,
                  let width = bounds["Width"] as? CGFloat,
                  let height = bounds["Height"] as? CGFloat,
                  width > 0,
                  height > 0
            else {
                continue
            }

            for screen in NSScreen.screens {
                let convertedFrame = NSRect(
                    x: x,
                    y: screen.frame.maxY - y - height,
                    width: width,
                    height: height
                )
                if screen.frame.intersects(convertedFrame) {
                    return convertedFrame
                }
            }

            let convertedY = (NSScreen.main?.frame.maxY ?? 0) - y - height
            return NSRect(x: x, y: convertedY, width: width, height: height)
        }

        return nil
    }

    private func showAccessibilityGuidePanel(requestID: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            guard self.accessibilityGuideRequestID == requestID else { return }
            guard !self.refreshAccessibilityPermissionState() else {
                self.finishAccessibilityPermissionFlow()
                return
            }

            let settingsFrame = self.systemSettingsWindowFrame()
            let screen = settingsFrame
                .flatMap { frame in NSScreen.screens.first { $0.frame.intersects(frame) } } ?? NSScreen.main
            guard let screen else { return }

            let visibleFrame = screen.visibleFrame
            let panelWidth = min(max((settingsFrame?.width ?? visibleFrame.width * 0.48) * 0.86, 520), 760)
            let panelHeight: CGFloat = 132
            let gap: CGFloat = 14

            let panelX: CGFloat
            let panelY: CGFloat
            if let settingsFrame {
                panelX = min(
                    visibleFrame.maxX - panelWidth - 16,
                    max(visibleFrame.minX + 16, settingsFrame.midX - (panelWidth / 2))
                )
                panelY = max(visibleFrame.minY + 16, settingsFrame.minY - panelHeight - gap)
            } else {
                panelX = visibleFrame.midX - (panelWidth / 2)
                panelY = visibleFrame.minY + 120
            }

            let frame = NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight)
            let panel = self.accessibilityGuidePanel ?? NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )

            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.contentView = NSHostingView(
                rootView: AccessibilitySettingsFloatingGuideView(
                    appURL: self.draggableAccessibilityAppURL,
                    appName: self.accessibilityAppDisplayName,
                    onReturnToApp: {
                        self.cancelAccessibilityPermissionFlow()
                    },
                    onClose: {
                        self.cancelAccessibilityPermissionFlow()
                    }
                )
            )
            panel.setFrame(frame, display: true, animate: self.accessibilityGuidePanel != nil)
            panel.orderFrontRegardless()
            self.accessibilityGuidePanel = panel
            self.startAccessibilityGuidePanelMonitor()
            self.activateSystemSettingsSoon(requestID: requestID)
        }
    }

    private func activateSystemSettingsSoon(requestID: UUID) {
        for delay in [0.25, 0.85, 1.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard self.accessibilityGuideRequestID == requestID else { return }
                self.activateSystemSettings()
            }
        }
    }

    private func activateSystemSettings() {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.SystemSettings" }) ??
            NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.systempreferences" }) ??
            NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == "System Settings" })
        {
            app.activate(options: [])
        }
    }

    private func cancelAccessibilityPermissionFlow() {
        self.finishAccessibilityPermissionFlow()
        NSApp.activate(ignoringOtherApps: true)
        (NSApp.windows.first { $0.isVisible && $0.title == "FluidVoice" } ?? NSApp.keyWindow)?
            .makeKeyAndOrderFront(nil)
    }

    private func finishAccessibilityPermissionFlow() {
        self.accessibilityGuideRequestID = nil
        self.didOpenAccessibilityPane = false
        self.showRestartPrompt = false
        UserDefaults.standard.set(false, forKey: self.accessibilityRestartFlagKey)
        self.closeAccessibilityGuidePanel()
        self.stopAccessibilityPolling()
    }

    private func closeAccessibilityGuidePanel() {
        self.accessibilityGuideMonitorTask?.cancel()
        self.accessibilityGuideMonitorTask = nil
        self.accessibilityGuidePanel?.close()
        self.accessibilityGuidePanel = nil
    }

    private func startAccessibilityGuidePanelMonitor() {
        self.accessibilityGuideMonitorTask?.cancel()
        self.accessibilityGuideMonitorTask = Task {
            var missingSettingsCount = 0

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 900_000_000)

                let isTrusted = AXIsProcessTrusted()
                let settingsFrame = await MainActor.run {
                    self.systemSettingsWindowFrame()
                }

                if isTrusted {
                    await MainActor.run {
                        self.refreshAccessibilityPermissionState()
                        self.finishAccessibilityPermissionFlow()
                    }
                    return
                }

                if settingsFrame == nil {
                    missingSettingsCount += 1
                } else {
                    missingSettingsCount = 0
                }

                if missingSettingsCount >= 3 {
                    await MainActor.run {
                        self.cancelAccessibilityPermissionFlow()
                    }
                    return
                }
            }
        }
    }

    private var draggableAccessibilityAppURL: URL {
        let runningAppURL = Bundle.main.bundleURL
        if runningAppURL.pathExtension == "app",
           FileManager.default.fileExists(atPath: runningAppURL.path)
        {
            return runningAppURL
        }

        let installedURL = URL(fileURLWithPath: "/Applications/FluidVoice.app")
        if FileManager.default.fileExists(atPath: installedURL.path) {
            return installedURL
        }
        return Bundle.main.bundleURL
    }

    private var accessibilityAppDisplayName: String {
        Bundle.main.fluidAppDisplayName
    }

    func restartApp() {
        // Clear pending flag and hide prompt before restarting
        UserDefaults.standard.set(false, forKey: self.accessibilityRestartFlagKey)
        self.showRestartPrompt = false
        AppDelegate.restartAfterSaving()
    }

    func startAccessibilityPolling() {
        // Keep polling until macOS reports the current process is trusted. The restart guard
        // only prevents restart loops; it must not prevent the UI from noticing permission changes.
        guard !self.accessibilityEnabled else { return }

        // Cancel any existing polling task
        self.accessibilityPollingTask?.cancel()

        // Start background polling
        self.accessibilityPollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000) // Poll every 2 seconds

                // Check if permission was granted
                let nowTrusted = AXIsProcessTrusted()
                if nowTrusted && !self.accessibilityEnabled {
                    await MainActor.run {
                        DebugLogger.shared.info("Accessibility permission granted", source: "ContentView")
                        self.refreshAccessibilityPermissionState()
                        self.finishAccessibilityPermissionFlow()
                    }
                    break // Stop polling after triggering restart
                }
            }
        }
    }

    private func stopAccessibilityPolling() {
        self.accessibilityPollingTask?.cancel()
        self.accessibilityPollingTask = nil
    }
}

@MainActor
private enum SidebarSymbolCache {
    private static let symbolNames = [
        "waveform",
        "brain",
        "cpu",
        "wand.and.stars",
        "text.book.closed.fill",
        "terminal.fill",
        "doc.text.fill",
        "person.2.fill",
        "clock.arrow.circlepath",
        "chart.bar.fill",
        "house.fill",
        "doc.text.magnifyingglass",
        "envelope.fill",
    ]

    private static let images: [String: NSImage] = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            .applying(.preferringHierarchical())
        var images: [String: NSImage] = [:]

        for name in symbolNames {
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            else { continue }

            image.isTemplate = true
            image.cacheMode = .always
            images[name] = image
        }

        return images
    }()

    static func image(named name: String) -> NSImage {
        self.images[name] ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil) ?? NSImage()
    }
}

private struct SidebarChromeButtonStyle: ButtonStyle {
    let isHovered: Bool
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        let scale = self.reduceMotion || !configuration.isPressed ? 1 : 0.985

        configuration.label
            .foregroundStyle(.primary)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(self.backgroundOpacity(isPressed: configuration.isPressed)))
            )
            .scaleEffect(scale)
            .animation(.easeOut(duration: self.reduceMotion ? 0.08 : 0.1), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.1), value: self.isHovered)
    }

    private func backgroundOpacity(isPressed: Bool) -> Double {
        if isPressed {
            return 0.12
        }
        return self.isHovered ? 0.08 : 0
    }
}

extension View {
    func sidebarOptionHover(isSelected: Bool, reduceMotion: Bool) -> some View {
        modifier(SidebarOptionHoverModifier(isSelected: isSelected, reduceMotion: reduceMotion))
    }
}

private struct SidebarOptionHoverModifier: ViewModifier {
    let isSelected: Bool
    let reduceMotion: Bool

    @Environment(\.theme) private var theme
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(self.backgroundColor)
            )
            .padding(.horizontal, -5)
            .padding(.vertical, -3)
            .contentShape(Rectangle())
            .onHover { self.isHovered = $0 }
            .animation(.easeOut(duration: self.reduceMotion ? 0.08 : 0.12), value: self.isHovered)
    }

    private var backgroundColor: Color {
        if self.isSelected {
            return self.theme.palette.accent
        }
        return Color.primary.opacity(self.isHovered ? 0.08 : 0)
    }
}

private struct AccessibilitySettingsFloatingGuideView: View {
    let appURL: URL
    let appName: String
    let onReturnToApp: () -> Void
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isArrowRaised = false
    @State private var isTokenHovered = false

    private var appIcon: NSImage {
        NSWorkspace.shared.icon(forFile: self.appURL.path)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.up")
                    .font(.fluidSystem(size: 30, weight: .bold))
                    .foregroundStyle(FluidOnboardingLandingColors.blue)
                    .offset(y: self.reduceMotion ? 0 : (self.isArrowRaised ? -8 : 4))
                    .animation(
                        self.reduceMotion ? nil : .easeInOut(duration: 0.85).repeatForever(autoreverses: true),
                        value: self.isArrowRaised
                    )

                Text("Drag \(self.appName) into the Accessibility apps list as shown")
                    .font(.fluidSystem(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)

                Spacer()

                Button {
                    self.onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.fluidSystem(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.58))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.075)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Close guide")
            }

            HStack(spacing: 12) {
                Button {
                    self.onReturnToApp()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.fluidSystem(size: 15, weight: .bold))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.white.opacity(0.075)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Return to \(self.appName)")

                Image(nsImage: self.appIcon)
                    .resizable()
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(self.appName)
                    .font(.fluidSystem(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))

                Spacer()

                Image(systemName: "line.3.horizontal")
                    .font(.fluidSystem(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.38))
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(self.isTokenHovered ? 0.095 : 0.055))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(self.isTokenHovered ? 0.16 : 0.08), lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onHover { isHovered in
                if self.reduceMotion {
                    self.isTokenHovered = isHovered
                } else {
                    withAnimation(.easeOut(duration: 0.14)) {
                        self.isTokenHovered = isHovered
                    }
                }
            }
            .onDrag {
                NSItemProvider(object: self.appURL as NSURL)
            }
            .accessibilityLabel("Drag \(self.appName) to the Accessibility list")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.11, green: 0.11, blue: 0.13).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
        )
        .onAppear {
            guard !self.reduceMotion else { return }
            self.isArrowRaised = true
        }
    }
}

private extension ContentView {
    // Shortcut values live in SettingsStore; these read and write it so call sites stay short.
    var primaryDictationShortcuts: [HotkeyShortcut] {
        get { self.settings.primaryDictationShortcuts }
        nonmutating set { self.settings.primaryDictationShortcuts = newValue }
    }

    var promptModeHotkeyShortcut: HotkeyShortcut {
        get { self.settings.promptModeHotkeyShortcut }
        nonmutating set { self.settings.promptModeHotkeyShortcut = newValue }
    }

    var commandModeHotkeyShortcut: HotkeyShortcut? {
        get { self.settings.commandModeHotkeyShortcut }
        nonmutating set { self.settings.commandModeHotkeyShortcut = newValue }
    }

    var rewriteModeHotkeyShortcut: HotkeyShortcut {
        get { self.settings.rewriteModeHotkeyShortcut }
        nonmutating set { self.settings.rewriteModeHotkeyShortcut = newValue }
    }

    var cancelRecordingHotkeyShortcut: HotkeyShortcut? {
        get { self.settings.cancelRecordingHotkeyShortcut }
        nonmutating set { self.settings.cancelRecordingHotkeyShortcut = newValue }
    }

    var pasteLastTranscriptionHotkeyShortcut: HotkeyShortcut? {
        get { self.settings.pasteLastTranscriptionHotkeyShortcut }
        nonmutating set { self.settings.pasteLastTranscriptionHotkeyShortcut = newValue }
    }

    var isPasteLastTranscriptionShortcutEnabled: Bool {
        get { self.settings.pasteLastTranscriptionShortcutEnabled }
        nonmutating set { self.settings.pasteLastTranscriptionShortcutEnabled = newValue }
    }

    var isPromptModeShortcutEnabled: Bool {
        get { self.settings.promptModeShortcutEnabled }
        nonmutating set { self.settings.promptModeShortcutEnabled = newValue }
    }

    var isCommandModeShortcutEnabled: Bool {
        get { FluidWisprBuild.includesCommandMode && self.settings.commandModeShortcutEnabled }
        nonmutating set { self.settings.commandModeShortcutEnabled = newValue }
    }

    var commandModeShortcutEnabledBinding: Binding<Bool> {
        Binding(get: { self.isCommandModeShortcutEnabled }, set: { self.isCommandModeShortcutEnabled = $0 })
    }

    var isRewriteModeShortcutEnabled: Bool {
        get { self.settings.rewriteModeShortcutEnabled }
        nonmutating set { self.settings.rewriteModeShortcutEnabled = newValue }
    }

    var hotkeyMode: HotkeyActivationMode {
        self.settings.hotkeyMode
    }

    /// Shortcut and preference values are read from SettingsStore directly, and their onChange
    /// handlers update the hotkey manager, so only the devices and prompt shortcuts need reloading here.
    func reloadSettingsStateAfterBackupRestore() {
        self.selectedOutputUID = SettingsStore.shared.preferredOutputDeviceUID ?? ""
        self.hotkeyManager?.updatePromptShortcutAssignments(SettingsStore.shared.dictationPromptShortcutAssignments())

        self.refreshDevices()
    }
}

private struct UpdateAvailableToolbarButton: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var updater = SimpleUpdater.shared

    var body: some View {
        if let version = self.updater.availableUpdateVersion {
            Button {
                self.updater.showAvailableUpdate()
            } label: {
                Image(systemName: "arrow.down.circle.fill")
                    .fluidToolbarIcon()
                    .foregroundStyle(self.theme.palette.accent)
            }
            .buttonStyle(.automatic)
            .disabled(self.updater.isCheckingForUpdates || self.updater.isUpdateInProgress)
            .help("Update available: \(version). View update.")
            .accessibilityLabel("Update available: \(version)")
            .accessibilityHint("View update details")
        }
    }
}

private struct TodayStatsToolbarButton: View {
    @ObservedObject private var historyStore = TranscriptionHistoryStore.shared

    let typingWPM: Int
    let action: () -> Void

    var body: some View {
        let summary = self.historyStore.todaySummary
        let timeSaved = summary.formattedTimeSaved(typingWPM: self.typingWPM)
        let hasActivity = summary.words > 0

        return Button(action: self.action) {
            HStack(spacing: 4) {
                Image(systemName: hasActivity ? "waveform" : "chart.bar.fill")
                if hasActivity {
                    Text("\(summary.words) words")
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(timeSaved)
                } else {
                    Text("Today")
                }
            }
            .font(.fluidSystem(size: 12, weight: .medium))
        }
        .help(hasActivity ? "Today: \(summary.words) words · \(timeSaved) saved - view stats" : "View your stats")
        .accessibilityLabel("Today stats")
    }
}

// MARK: - Card Animation Modifier

struct CardAppearAnimation: ViewModifier {
    let delay: Double
    @Binding var appear: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(self.appear ? 1.0 : 0.96)
            .opacity(self.appear ? 1.0 : 0)
            .animation(.spring(response: 0.8, dampingFraction: 0.75, blendDuration: 0.2).delay(self.delay), value: self.appear)
    }
}
