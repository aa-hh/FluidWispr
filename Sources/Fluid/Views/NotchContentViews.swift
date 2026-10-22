//
//  NotchContentViews.swift
//  Fluid
//
//  Created by Assistant
//

import AppKit
import Combine
import QuartzCore
import SwiftUI

enum SpokenSendIndicatorState: Equatable {
    case hidden
    case detected
    case countingDown
    case sending
    case sent
    case failed

    var isVisible: Bool {
        self != .hidden
    }
}

struct SpokenSendIndicatorView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0

    let state: SpokenSendIndicatorState
    let color: Color
    let size: CGFloat

    var body: some View {
        Group {
            switch self.state {
            case .hidden:
                EmptyView()
            case .detected:
                self.symbol("paperplane.fill", color: self.color, accessibilityLabel: "Send detected")
            case .countingDown:
                ZStack {
                    Circle()
                        .stroke(self.color.opacity(0.22), lineWidth: self.lineWidth)

                    Circle()
                        .trim(from: 0, to: self.progress)
                        .stroke(
                            self.color,
                            style: StrokeStyle(lineWidth: self.lineWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))

                    self.symbol("paperplane.fill", color: self.color, accessibilityLabel: "Waiting to send")
                }
                .onAppear {
                    guard !self.reduceMotion else {
                        self.progress = 1
                        return
                    }
                    withAnimation(.linear(duration: SpokenSendParser.immediateStopSettleDuration)) {
                        self.progress = 1
                    }
                }
            case .sending:
                ZStack {
                    Circle()
                        .stroke(self.color, lineWidth: self.lineWidth)
                    self.symbol("paperplane.fill", color: self.color, accessibilityLabel: "Sending")
                }
            case .sent:
                self.symbol("checkmark.circle.fill", color: self.color, accessibilityLabel: "Sent")
            case .failed:
                self.symbol("exclamationmark.circle.fill", color: .orange, accessibilityLabel: "Send skipped")
            }
        }
        .frame(width: self.size, height: self.size)
    }

    private var lineWidth: CGFloat {
        max(1, self.size * 0.085)
    }

    private func symbol(_ name: String, color: Color, accessibilityLabel: String) -> some View {
        Image(systemName: name)
            .font(.fluidSystem(size: max(6, self.size * 0.46), weight: .semibold))
            .foregroundStyle(color)
            .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Observable state for notch content (Singleton)

@MainActor
class NotchContentState: ObservableObject {
    static let shared = NotchContentState()
    /// Keep overlay state bounded even during very long recordings.
    private static let maxStoredTranscriptionCharacters = SettingsStore.transcriptionPreviewCharLimitRange.upperBound

    @Published var transcriptionText: String = ""
    @Published var mode: OverlayMode = .dictation
    @Published var promptPickerMode: SettingsStore.PromptMode = .dictate
    @Published var isProcessing: Bool = false // AI processing state
    @Published var isDictationMuted = false
    @Published var isAIProcessingFailureVisible: Bool = false
    @Published private(set) var aiProcessingFailureMessage: String = "AI Enhancement failed"
    @Published private(set) var canRetryAIProcessingFailure: Bool = true
    @Published private(set) var spokenSendIndicatorState: SpokenSendIndicatorState = .hidden
    @Published private(set) var spokenSendCountdownID: UInt64 = 0
    @Published var isTextDeliveryFailureVisible: Bool = false
    @Published private(set) var textDeliveryFailureMessage: String = "Text could not be inserted"
    private(set) var textDeliveryFailureTranscript: String = ""
    private(set) var textDeliveryFailure: TextDeliveryFailure?
    @Published var activeDictationShortcutSlot: SettingsStore.DictationShortcutSlot? = nil
    @Published var stopSnapshotLabel: String?
    @Published var promptModeOverrideProfileName: String? = nil // Name shown in overlay when prompt mode hotkey is active
    @Published var promptModeOverrideProfileID: String? = nil // ID of the active override profile (for checkmark in menu)
    @Published var isPromptModeActive: Bool = false // True for the entire prompt-mode session, even when no profile is selected

    /// Called when the user picks a different dictation prompt from the overlay during recording.
    var onDictationPromptSelectionRequested: ((SettingsStore.DictationPromptSelection) -> Void)?

    /// Icon of the target app (where text will be typed)
    @Published var targetAppIcon: NSImage?

    /// The PID of the app we should restore focus to after interacting with overlays.
    /// Captured at recording start to keep the target stable for the session.
    @Published var recordingTargetPID: pid_t? = nil
    var recordingTargetContext: TypingService.RecordingTargetContext?

    /// Cached transcription preview text to avoid recomputing on every render
    @Published private(set) var cachedPreviewText: String = ""

    // MARK: - Expanded Command Output State

    @Published var isExpandedForCommandOutput: Bool = false
    @Published var commandOutput: String = "" // Final or streaming output
    @Published var commandStreamingText: String = "" // Real-time streaming text
    @Published var commandInputText: String = "" // User's follow-up input
    @Published var commandConversationHistory: [CommandOutputMessage] = []
    @Published var isCommandProcessing: Bool = false

    // MARK: - Chat History State

    @Published var recentChats: [ChatSession] = []
    @Published var currentChatTitle: String = "New Chat"

    /// Command output message model
    struct CommandOutputMessage: Identifiable, Equatable {
        let id = UUID()
        let role: Role
        let content: String
        let timestamp: Date = .init()

        enum Role: Equatable {
            case user
            case assistant
            case status // For "Running...", "Checking...", etc.
        }
    }

    /// Callback for submitting follow-up commands from the notch
    var onSubmitFollowUp: ((String) async -> Void)?

    private var cancellables = Set<AnyCancellable>()

    private init() {
        let previewLimitChanged = NotificationCenter.default.publisher(
            for: NSNotification.Name("TranscriptionPreviewCharLimitChanged")
        )
        let defaultsChanged = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)

        Publishers.Merge(previewLimitChanged, defaultsChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recomputeTranscriptionLines()
            }
            .store(in: &self.cancellables)
    }

    /// Set AI processing state
    func setProcessing(_ processing: Bool) {
        if processing {
            self.clearAIProcessingFailure()
            self.clearTextDeliveryFailure()
        }
        self.isProcessing = processing
    }

    func showAIProcessingFailure(
        message: String = "AI Enhancement failed",
        canRetry: Bool = true
    ) {
        self.aiProcessingFailureMessage = message
        self.canRetryAIProcessingFailure = canRetry
        self.isAIProcessingFailureVisible = true
    }

    func clearAIProcessingFailure() {
        self.isAIProcessingFailureVisible = false
    }

    func setSpokenSendIndicatorState(_ state: SpokenSendIndicatorState) {
        guard self.spokenSendIndicatorState != state else { return }
        self.spokenSendIndicatorState = state
    }

    @discardableResult
    func beginSpokenSendCountdown() -> UInt64 {
        self.spokenSendCountdownID &+= 1
        self.spokenSendIndicatorState = .countingDown
        return self.spokenSendCountdownID
    }

    func recordTextDeliveryFailure(_ failure: TextDeliveryFailure, transcript: String) {
        self.textDeliveryFailureTranscript = transcript
        self.textDeliveryFailure = failure
        self.textDeliveryFailureMessage = failure.userFacingMessage ?? ""
        self.isTextDeliveryFailureVisible = failure.userFacingMessage != nil
    }

    func clearTextDeliveryFailure() {
        self.isTextDeliveryFailureVisible = false
        self.textDeliveryFailure = nil
    }

    /// Update transcription and recompute cached lines
    func updateTranscription(_ text: String) {
        let boundedText = Self.tailCharacters(in: text, maxCharacters: Self.maxStoredTranscriptionCharacters)
        guard boundedText != self.transcriptionText else { return }

        self.transcriptionText = boundedText
        self.recomputeTranscriptionLines()
    }

    /// Recompute cached transcription lines (called only when text changes)
    private func recomputeTranscriptionLines() {
        let text = self.transcriptionText

        guard !text.isEmpty else {
            if !self.cachedPreviewText.isEmpty {
                self.cachedPreviewText = ""
            }
            return
        }

        let maxChars = SettingsStore.shared.transcriptionPreviewCharLimit
        let previewText = Self.tailCharacters(in: text, maxCharacters: maxChars)
        guard previewText != self.cachedPreviewText else { return }
        self.cachedPreviewText = previewText
    }

    private static func tailCharacters(in text: String, maxCharacters: Int) -> String {
        guard maxCharacters > 0, !text.isEmpty else { return "" }

        let start = text.index(text.endIndex, offsetBy: -maxCharacters, limitedBy: text.startIndex) ?? text.startIndex
        return String(text[start..<text.endIndex])
    }

    // MARK: - Recording State for Expanded View

    @Published var isRecordingInExpandedMode: Bool = false
    @Published var expandedModeAudioLevel: CGFloat = 0 // Audio level for waveform in expanded mode

    // MARK: - Bottom Overlay Audio Level

    @Published var bottomOverlayAudioLevel: CGFloat = 0 // Audio level for bottom overlay waveform
    @Published var isBottomOverlayPresented: Bool = false
    @Published var isBottomOverlayReleaseTransitioning: Bool = false
    @Published var isBottomOverlayDismissing: Bool = false
    @Published var bottomOverlayDismissOffsetY: CGFloat = 8

    /// Called when the user requests a live mode switch from the prompt picker tabs.
    var onPromptModeSwitchRequested: ((SettingsStore.PromptMode) -> Void)?
    /// Called when the user requests a live overlay mode switch from the mode picker.
    var onOverlayModeSwitchRequested: ((OverlayMode) -> Void)?
    /// Called when the user requests reprocessing the latest saved dictation entry.
    var onReprocessLastRequested: (() -> Void)?
    /// Called when the user requests copying the latest saved transcription entry.
    var onCopyLastRequested: (() -> Void)?
    /// Called when the user requests re-pasting the latest saved transcription entry.
    var onPasteLastRequested: (() -> Void)?
    /// Called when the user retries the exact transcript from a delivery failure.
    var onRetryTextDeliveryRequested: ((String) -> Void)?
    /// Called when the user requests undoing AI processing for the latest entry.
    var onUndoLastAIRequested: (() -> Void)?
    /// Called when the user requests opening Preferences.
    var onOpenPreferencesRequested: (() -> Void)?
    /// Called when the user requests cancelling the current recording or overlay session.
    var onCancelRequested: (() -> Void)?

    /// Set recording state (for waveform visibility in expanded view)
    func setRecordingInExpandedMode(_ recording: Bool) {
        self.isRecordingInExpandedMode = recording
        if !recording {
            self.expandedModeAudioLevel = 0
        }
    }

    /// Update audio level for expanded mode waveform
    func updateExpandedModeAudioLevel(_ level: CGFloat) {
        guard self.isRecordingInExpandedMode else { return }
        self.expandedModeAudioLevel = level
    }

    func setBottomOverlayReleaseTransitioning(_ transitioning: Bool) {
        guard self.isBottomOverlayReleaseTransitioning != transitioning else { return }
        self.isBottomOverlayReleaseTransitioning = transitioning
    }

    func setBottomOverlayPresented(_ presented: Bool) {
        guard self.isBottomOverlayPresented != presented else { return }
        self.isBottomOverlayPresented = presented
    }

    func setBottomOverlayDismissing(_ dismissing: Bool) {
        guard self.isBottomOverlayDismissing != dismissing else { return }
        self.isBottomOverlayDismissing = dismissing
    }

    func setBottomOverlayDismissOffsetY(_ offset: CGFloat) {
        let normalizedOffset = max(offset, 8)
        guard abs(self.bottomOverlayDismissOffsetY - normalizedOffset) > 0.5 else { return }
        self.bottomOverlayDismissOffsetY = normalizedOffset
    }

    // MARK: - Command Output Methods

    /// Show expanded output view with content
    func showExpandedCommandOutput(output: String) {
        self.commandOutput = output
        self.commandStreamingText = ""
        self.isExpandedForCommandOutput = true
        self.isRecordingInExpandedMode = false // Not recording when first showing output
    }

    /// Update streaming text in real-time
    func updateCommandStreamingText(_ text: String) {
        self.commandStreamingText = text
    }

    /// Add a message to the conversation history
    func addCommandMessage(role: CommandOutputMessage.Role, content: String) {
        let message = CommandOutputMessage(role: role, content: content)
        self.commandConversationHistory.append(message)
    }

    /// Set command processing state
    func setCommandProcessing(_ processing: Bool) {
        self.isCommandProcessing = processing
    }

    /// Clear command output and hide expanded view
    func clearCommandOutput() {
        self.isExpandedForCommandOutput = false
        self.commandOutput = ""
        self.commandStreamingText = ""
        self.commandInputText = ""
        self.commandConversationHistory.removeAll()
        self.isCommandProcessing = false
    }

    /// Hide expanded view but keep history
    func collapseCommandOutput() {
        self.isExpandedForCommandOutput = false
    }

    // MARK: - Chat History Methods

    /// Refresh recent chats from store
    func refreshRecentChats() {
        self.recentChats = ChatHistoryStore.shared.getRecentChats(excludingCurrent: false)
        if let current = ChatHistoryStore.shared.currentSession {
            self.currentChatTitle = current.title
        }
    }
}

// MARK: - Shared Mode Color Helper

extension OverlayMode {
    /// The colour of notch UI elements: one colour for every mode, with no blue for Edit Mode or red for Command Mode.
    var notchColor: Color {
        Color.white.opacity(0.85)
    }
}

// MARK: - Shimmer Text (Cursor-style thinking animation)

struct CompositorShimmerSweep: NSViewRepresentable {
    var duration: CFTimeInterval = 1.0
    var peakOpacity: CGFloat = 0.88

    func makeNSView(context: Context) -> CompositorShimmerSweepView {
        let view = CompositorShimmerSweepView()
        view.configure(duration: self.duration, peakOpacity: self.peakOpacity)
        return view
    }

    func updateNSView(_ nsView: CompositorShimmerSweepView, context: Context) {
        nsView.configure(duration: self.duration, peakOpacity: self.peakOpacity)
    }
}

final class CompositorShimmerSweepView: NSView {
    private let gradientLayer = CAGradientLayer()
    private var animationDuration: CFTimeInterval = 1.0
    private var peakOpacity: CGFloat = 0.88

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true

        let backingLayer = CALayer()
        backingLayer.masksToBounds = true
        self.layer = backingLayer

        self.gradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        self.gradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        self.gradientLayer.locations = [-0.45, -0.15, 0.15]
        backingLayer.addSublayer(self.gradientLayer)
        self.updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.gradientLayer.frame = self.bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if self.window == nil {
            self.gradientLayer.removeAnimation(forKey: "fluid.shimmer.locations")
        } else {
            self.startAnimationIfNeeded()
        }
    }

    func configure(duration: CFTimeInterval, peakOpacity: CGFloat) {
        let clampedDuration = max(duration, 0.2)
        let clampedOpacity = min(max(peakOpacity, 0.0), 1.0)
        let shouldRestart = abs(self.animationDuration - clampedDuration) > 0.01
        let shouldUpdateColors = abs(self.peakOpacity - clampedOpacity) > 0.01

        self.animationDuration = clampedDuration
        self.peakOpacity = clampedOpacity
        if shouldUpdateColors {
            self.updateColors()
        }
        if shouldRestart {
            self.startAnimationIfNeeded()
        }
    }

    private func updateColors() {
        self.gradientLayer.colors = [
            NSColor.white.withAlphaComponent(0).cgColor,
            NSColor.white.withAlphaComponent(self.peakOpacity).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ]
    }

    private func startAnimationIfNeeded() {
        guard self.window != nil else { return }
        self.gradientLayer.removeAnimation(forKey: "fluid.shimmer.locations")

        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-0.45, -0.15, 0.15]
        animation.toValue = [0.85, 1.15, 1.45]
        animation.duration = self.animationDuration
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false

        self.gradientLayer.add(animation, forKey: "fluid.shimmer.locations")
    }
}

// MARK: - Expanded View (Main Content) - Minimal Design

struct NotchExpandedView: View {
    let audioPublisher: AnyPublisher<CGFloat, Never>
    @ObservedObject private var contentState = NotchContentState.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var activeAppMonitor = ActiveAppMonitor.shared
    @Environment(\.theme) private var theme
    @State private var isHoveringPromptChip = false
    @State private var isHoveringPromptMenu = false
    @State private var hoveredPromptMenuRowID: String?
    @State private var showPromptHoverMenu = false
    @State private var promptHoverGeneration: UInt64 = 0
    @State private var promptSelectorLeading: CGFloat = 0

    private var modeColor: Color {
        self.contentState.mode.notchColor
    }

    private var showsSpokenSendIndicator: Bool {
        self.contentState.mode == .dictation &&
            self.settings.spokenSendEnabled &&
            self.contentState.spokenSendIndicatorState.isVisible
    }

    private var presentationPolicy: NotchOverlayManager.NotchPresentationPolicy {
        NotchOverlayManager.shared.currentNotchPresentationPolicy
    }

    private var processingLabel: String {
        switch self.contentState.mode {
        case .dictation: return "Transcribing"
        case .edit, .rewrite, .write: return "Thinking"
        case .command: return "Working"
        }
    }

    private static let transientOverlayStatusTexts: Set<String> = [
        "Transcribing",
        "Refining",
        "Thinking",
        "Working",
        "Transcribing...",
        "Refining...",
        "Thinking...",
        "Working...",
    ]

    /// ContentView writes transient status strings into transcriptionText while processing
    /// (e.g. "Transcribing...", "Refining..."). Prefer that when present.
    private var processingStatusText: String {
        let t = self.contentState.transcriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.transientOverlayStatusTexts.contains(t) else { return self.processingLabel }
        return t
    }

    private var hasTranscription: Bool {
        !self.visiblePreviewText.isEmpty
    }

    private var visiblePreviewText: String {
        let previewText = self.contentState.cachedPreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.transientOverlayStatusTexts.contains(previewText) else { return "" }
        return previewText
    }

    /// Check if there's command history that can be expanded
    private var canExpandCommandHistory: Bool {
        self.presentationPolicy.allowsCommandExpansion &&
            self.presentationPolicy.allowsCommandActions &&
            self.contentState.mode == .command &&
            !self.contentState.commandConversationHistory.isEmpty
    }

    private var normalizedOverlayMode: OverlayMode {
        switch self.contentState.mode {
        case .dictation:
            return .dictation
        case .edit, .write, .rewrite:
            return .edit
        case .command:
            return .command
        }
    }

    private var activePromptMode: SettingsStore.PromptMode? {
        switch self.normalizedOverlayMode {
        case .dictation:
            return .dictate
        case .edit:
            return .edit
        case .command, .write, .rewrite:
            return nil
        }
    }

    private var isPromptSelectableMode: Bool {
        self.activePromptMode != nil
    }

    private var promptResolutionBundleID: String? {
        DictationAppSession.shared.appID
    }

    private var activeDictationShortcutSlot: SettingsStore.DictationShortcutSlot {
        self.contentState.activeDictationShortcutSlot ?? .primary
    }

    private var isAppPromptOverrideActive: Bool {
        guard let activePromptMode else { return false }
        if activePromptMode.normalized == .dictate {
            return self.settings.isAppDictationPromptBindingActive(
                for: self.activeDictationShortcutSlot,
                appBundleID: self.promptResolutionBundleID
            )
        }
        return self.settings.hasAppPromptBinding(
            for: activePromptMode,
            appBundleID: self.promptResolutionBundleID
        )
    }

    private var selectedPromptLabel: String {
        guard let activePromptMode else { return "N/A" }
        if activePromptMode.normalized == .dictate {
            if let label = self.contentState.stopSnapshotLabel { return label }
            return self.settings.dictationOverlayLabel(
                for: self.activeDictationShortcutSlot,
                appBundleID: self.promptResolutionBundleID
            )
        }
        if let profile = self.settings.resolvedPromptProfile(
            for: activePromptMode,
            appBundleID: self.promptResolutionBundleID
        ) {
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? "Untitled" : name
        }
        return "Default"
    }

    private var compactPromptLabel: String {
        self.selectedPromptLabel
    }

    private var previewMaxHeight: CGFloat {
        60
    }

    private var previewMaxWidth: CGFloat {
        180
    }

    private var promptSelectorFixedWidth: CGFloat {
        self.showsSpokenSendIndicator ? 82 : 100
    }

    private var promptMenuWidth: CGFloat {
        self.promptSelectorFixedWidth
    }

    private var promptMenuRowVerticalPadding: CGFloat {
        4
    }

    private var promptMenuMaxVisibleRows: CGFloat {
        3
    }

    private var promptMenuRowHeight: CGFloat {
        21
    }

    private var promptMenuListMaxHeight: CGFloat {
        self.promptMenuRowHeight * self.promptMenuMaxVisibleRows
    }

    private static let notchContentCoordinateSpace = "NotchExpandedContent"

    private var notchContentWidth: CGFloat {
        176
    }

    @ViewBuilder
    private var appIconView: some View {
        if let appIcon = self.contentState.targetAppIcon ?? self.activeAppMonitor.activeAppIcon {
            Image(nsImage: appIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }

    private func updatePromptMenuVisibility() {
        guard self.isPromptSelectableMode, !self.contentState.isProcessing else {
            self.dismissPromptHoverMenu()
            return
        }

        let shouldShow = self.isHoveringPromptChip || self.isHoveringPromptMenu
        self.promptHoverGeneration &+= 1
        let generation = self.promptHoverGeneration
        let delay = shouldShow ? 0.03 : 0.28
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard generation == self.promptHoverGeneration else { return }
            self.showPromptHoverMenu = shouldShow
        }
    }

    private func dismissPromptHoverMenu() {
        self.promptHoverGeneration &+= 1
        self.isHoveringPromptChip = false
        self.isHoveringPromptMenu = false
        self.hoveredPromptMenuRowID = nil
        self.showPromptHoverMenu = false
    }

    private func handlePromptChipHover(_ hovering: Bool) {
        self.isHoveringPromptChip = hovering
        self.updatePromptMenuVisibility()
    }

    private func handlePromptMenuHover(_ hovering: Bool) {
        self.isHoveringPromptMenu = hovering
        self.updatePromptMenuVisibility()
    }

    private func restoreRecordingTargetFocus() {
        guard let context = NotchContentState.shared.recordingTargetContext else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            _ = await TypingService.prepareTargetForDelivery(context)
        }
    }

    private func promptMenuRowBackground(isSelected: Bool, rowID: String) -> some View {
        let isHovered = self.hoveredPromptMenuRowID == rowID
        let fillColor: Color
        if isSelected {
            fillColor = Color.white.opacity(0.18)
        } else if isHovered {
            fillColor = Color.white.opacity(0.10)
        } else {
            fillColor = .clear
        }

        let strokeColor: Color
        if isSelected {
            strokeColor = Color.white.opacity(0.24)
        } else if isHovered {
            strokeColor = Color.white.opacity(0.14)
        } else {
            strokeColor = .clear
        }

        return RoundedRectangle(cornerRadius: 7)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(strokeColor, lineWidth: 1)
            )
    }

    private func promptMenuRow(
        _ title: String,
        rowID: String,
        isSelected: Bool,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            guard isEnabled else { return }
            action()
        }) {
            Text(title)
                .font(.fluidSystem(size: 9, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(.white.opacity(isSelected ? 0.96 : 0.84))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, self.promptMenuRowVerticalPadding)
                .background(self.promptMenuRowBackground(isSelected: isSelected, rowID: rowID))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering in
            self.hoveredPromptMenuRowID = hovering && isEnabled ? rowID : nil
        }
    }

    private func promptMenuContent() -> some View {
        let promptMode = self.activePromptMode ?? .dictate
        let activeDictationSlot = self.activeDictationShortcutSlot
        return VStack(alignment: .leading, spacing: 2) {
            Text("AI Prompt")
                .font(.fluidSystem(size: 8, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.42))
                .padding(.horizontal, 6)
                .padding(.top, 2)
                .padding(.bottom, 3)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 2) {
                    let defaultAvailable = promptMode.normalized != .dictate
                        || DictationProviderRoute.isDictationDefaultAvailable(settings: self.settings, appBundleID: self.promptResolutionBundleID)
                    let defaultSelected = defaultAvailable && (promptMode.normalized == .dictate
                        ? (self.settings.resolvedDictationPromptSelection(for: activeDictationSlot, appBundleID: self.promptResolutionBundleID) == .default)
                        : (self.settings.selectedPromptID(for: promptMode) == nil))

                    if promptMode.normalized == .dictate {
                        self.promptMenuRow(
                            "Basic",
                            rowID: "off",
                            isSelected: {
                                let selection = self.settings.resolvedDictationPromptSelection(for: activeDictationSlot, appBundleID: self.promptResolutionBundleID)
                                return selection == .off || (selection == .default && !defaultAvailable)
                            }(),
                            isEnabled: true
                        ) {
                            self.contentState.onDictationPromptSelectionRequested?(.off)
                            self.restoreRecordingTargetFocus()
                            self.dismissPromptHoverMenu()
                        }
                    }

                    self.promptMenuRow(
                        SettingsStore.DictationModeLabels.externalDefault,
                        rowID: "default",
                        isSelected: defaultSelected,
                        isEnabled: defaultAvailable
                    ) {
                        if promptMode.normalized == .dictate {
                            self.contentState.onDictationPromptSelectionRequested?(.default)
                        } else {
                            self.settings.setSelectedPromptID(nil, for: promptMode)
                        }
                        self.restoreRecordingTargetFocus()
                        self.dismissPromptHoverMenu()
                    }

                    if promptMode.normalized == .dictate && PrivateFeatures.privateAIProvider {
                        let privateAIAvailable = PrivateAIProviderPromptFormat.isAvailable(settings: self.settings)
                        self.promptMenuRow(
                            SettingsStore.DictationModeLabels.smartWithModel,
                            rowID: PrivateAIProviderFeature.shared.providerID,
                            isSelected: self.settings.resolvedDictationPromptSelection(for: activeDictationSlot, appBundleID: self.promptResolutionBundleID) == .privateAI,
                            isEnabled: privateAIAvailable
                        ) {
                            self.contentState.onDictationPromptSelectionRequested?(.privateAI)
                            self.restoreRecordingTargetFocus()
                            self.dismissPromptHoverMenu()
                        }
                    }

                    let profiles = self.settings.promptProfiles(for: promptMode)
                    if !profiles.isEmpty {
                        ForEach(profiles) { profile in
                            let isSelected = promptMode.normalized == .dictate
                                ? (self.settings.resolvedDictationPromptSelection(for: activeDictationSlot, appBundleID: self.promptResolutionBundleID) == .profile(profile.id))
                                : (self.settings.selectedPromptID(for: promptMode) == profile.id)
                            self.promptMenuRow(
                                profile.name.isEmpty ? "Untitled" : profile.name,
                                rowID: profile.id,
                                isSelected: isSelected
                            ) {
                                if promptMode.normalized == .dictate {
                                    self.contentState.onDictationPromptSelectionRequested?(.profile(profile.id))
                                } else {
                                    self.settings.setSelectedPromptID(profile.id, for: promptMode)
                                }
                                self.restoreRecordingTargetFocus()
                                self.dismissPromptHoverMenu()
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: self.promptMenuListMaxHeight)
        }
        .padding(3)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.24), radius: 8, x: 0, y: 5)
        .onHover { hovering in
            self.handlePromptMenuHover(hovering)
        }
    }

    @ViewBuilder
    private var promptSelectorControl: some View {
        if self.presentationPolicy.showsPromptSelector {
            HStack(spacing: 3) {
                Text(self.compactPromptLabel)
                    .help(self.selectedPromptLabel)
                    .accessibilityLabel(self.selectedPromptLabel)
                    .font(.fluidSystem(size: 9, weight: .medium))
                    .foregroundStyle(self.isHoveringPromptChip ? .white.opacity(0.94) : .white.opacity(0.86))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: false)
                Image(systemName: "chevron.down")
                    .font(.fluidSystem(size: 8, weight: .bold))
                    .foregroundStyle(self.isHoveringPromptChip ? .white.opacity(0.78) : .white.opacity(0.62))
                if self.isAppPromptOverrideActive {
                    Text("App")
                        .font(.fluidSystem(size: 8, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.82))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.12))
                        )
                }
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .frame(width: self.promptSelectorFixedWidth, alignment: .leading)
            .fluidDropdownSurface()
            .opacity(self.isPromptSelectableMode ? (self.contentState.isProcessing ? 0.7 : 1.0) : 0.6)
            .allowsHitTesting(self.isPromptSelectableMode && !self.contentState.isProcessing)
            .onHover { hovering in
                self.handlePromptChipHover(hovering)
            }
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            self.promptSelectorLeading = geometry.frame(in: .named(Self.notchContentCoordinateSpace)).minX
                        }
                        .onChange(of: geometry.frame(in: .named(Self.notchContentCoordinateSpace)).minX) { _, newLeading in
                            self.promptSelectorLeading = newLeading
                        }
                }
            )
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var promptHoverMenuRow: some View {
        if self.showPromptHoverMenu {
            HStack(spacing: 0) {
                Color.clear
                    .frame(width: self.promptSelectorLeading)

                self.promptMenuContent()
                    .frame(width: self.promptMenuWidth, alignment: .leading)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, -2)
            .transition(.opacity)
        }
    }

    var body: some View {
        Group {
            if self.canExpandCommandHistory {
                self.notchBodyContent
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if NotchOverlayManager.shared.canHandleNotchCommandTap {
                            NotchOverlayManager.shared.onNotchClicked?()
                        }
                    }
            } else {
                self.notchBodyContent
            }
        }
        .onChange(of: self.contentState.mode) { _, _ in
            if !self.isPromptSelectableMode {
                self.dismissPromptHoverMenu()
            }
            switch self.contentState.mode {
            case .dictation: self.contentState.promptPickerMode = .dictate
            case .edit, .write, .rewrite: self.contentState.promptPickerMode = .edit
            case .command: break
            }
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: self.hasTranscription)
        .animation(.easeInOut(duration: 0.2), value: self.contentState.mode)
        .animation(.easeInOut(duration: 0.25), value: self.contentState.isProcessing)
    }

    private var notchBodyContent: some View {
        VStack(alignment: .center, spacing: 6) {
            HStack(spacing: 4) {
                self.appIconView

                CompactNotchWaveformView(
                    audioPublisher: self.audioPublisher,
                    color: self.modeColor
                )
                .frame(width: 48, height: 18)

                self.promptSelectorControl

                if self.showsSpokenSendIndicator {
                    SpokenSendIndicatorView(
                        state: self.contentState.spokenSendIndicatorState,
                        color: self.modeColor,
                        size: 14
                    )
                    .id(self.contentState.spokenSendCountdownID)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .offset(x: 4, y: 0)
            .animation(.easeOut(duration: 0.14), value: self.contentState.spokenSendIndicatorState)

            self.promptHoverMenuRow

            if self.contentState.isTextDeliveryFailureVisible && !self.contentState.isProcessing {
                HStack(spacing: 6) {
                    Text(self.contentState.textDeliveryFailureMessage)
                        .font(.fluidSystem(size: 10, weight: .semibold))
                        .foregroundStyle(Color.orange.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 2)

                    Button {
                        _ = ClipboardService.copyToClipboard(self.contentState.textDeliveryFailureTranscript)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.fluidSystem(size: 9, weight: .bold))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help("Copy transcript")

                    Button {
                        let transcript = self.contentState.textDeliveryFailureTranscript
                        self.contentState.clearTextDeliveryFailure()
                        self.contentState.onRetryTextDeliveryRequested?(transcript)
                    } label: {
                        Image(systemName: "arrow.down.doc")
                            .font(.fluidSystem(size: 9, weight: .bold))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help("Paste last transcript")

                    Button {
                        self.contentState.clearTextDeliveryFailure()
                        NotchOverlayManager.shared.hide()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.fluidSystem(size: 9, weight: .bold))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: self.previewMaxWidth, alignment: .leading)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else if self.contentState.isAIProcessingFailureVisible && !self.contentState.isProcessing {
                HStack(spacing: 6) {
                    Text(self.contentState.aiProcessingFailureMessage)
                        .font(.fluidSystem(size: 10, weight: .semibold))
                        .foregroundStyle(
                            self.contentState.canRetryAIProcessingFailure
                                ? Color.white.opacity(0.82)
                                : Color.orange.opacity(0.9)
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 2)

                    if self.contentState.canRetryAIProcessingFailure {
                        Button {
                            self.contentState.clearAIProcessingFailure()
                            self.contentState.onReprocessLastRequested?()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.fluidSystem(size: 9, weight: .bold))
                                .frame(width: 16, height: 16)
                        }
                        .buttonStyle(.plain)
                        .help("Try again")
                    }

                    Button {
                        self.contentState.clearAIProcessingFailure()
                        NotchOverlayManager.shared.hide()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.fluidSystem(size: 9, weight: .bold))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: self.previewMaxWidth, alignment: .leading)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else if self.presentationPolicy.showsStreamingPreview && self.hasTranscription && !self.contentState.isProcessing {
                let previewText = self.visiblePreviewText
                if !previewText.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            Text(previewText)
                                .font(.fluidSystem(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.75))
                                .multilineTextAlignment(.leading)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .frame(width: self.previewMaxWidth, alignment: .leading)
                        .frame(maxHeight: self.previewMaxHeight, alignment: .leading)
                        .clipped()
                        .onAppear {
                            DispatchQueue.main.async {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                        .onChange(of: previewText) { _, _ in
                            DispatchQueue.main.async {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
        }
        .coordinateSpace(name: Self.notchContentCoordinateSpace)
        .frame(width: self.notchContentWidth)
        .padding(.horizontal, 6)
        .padding(.top, 0)
        .padding(.bottom, 4)
        .background(Color.black)
    }
}

// MARK: - Compact Views (Small States)

struct NotchCompactLeadingView: View {
    @ObservedObject private var contentState = NotchContentState.shared
    @ObservedObject private var activeAppMonitor = ActiveAppMonitor.shared

    var body: some View {
        Group {
            if let appIcon = self.contentState.targetAppIcon ?? self.activeAppMonitor.activeAppIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Circle()
                    .fill(self.contentState.mode.notchColor.opacity(0.9))
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 34, height: 16)
    }
}

struct NotchCompactTrailingView: View {
    let audioPublisher: AnyPublisher<CGFloat, Never>
    @ObservedObject private var contentState = NotchContentState.shared
    @ObservedObject private var settings = SettingsStore.shared

    private var showsSpokenSendIndicator: Bool {
        self.contentState.mode == .dictation &&
            self.settings.spokenSendEnabled &&
            self.contentState.spokenSendIndicatorState.isVisible
    }

    var body: some View {
        HStack(spacing: self.showsSpokenSendIndicator ? 4 : 0) {
            CompactNotchWaveformView(
                audioPublisher: self.audioPublisher,
                color: self.contentState.mode.notchColor,
                barCount: self.showsSpokenSendIndicator ? 4 : 8
            )
            .frame(width: self.showsSpokenSendIndicator ? 16 : 34, height: 16)

            if self.showsSpokenSendIndicator {
                SpokenSendIndicatorView(
                    state: self.contentState.spokenSendIndicatorState,
                    color: self.contentState.mode.notchColor,
                    size: 13
                )
                .id(self.contentState.spokenSendCountdownID)
            }
        }
        .frame(width: 34, height: 16)
        .animation(.easeOut(duration: 0.14), value: self.contentState.spokenSendIndicatorState)
    }
}

struct NotchCompactBottomView: View {
    @ObservedObject private var contentState = NotchContentState.shared

    private let previewWidth: CGFloat = 250
    private let previewHeight: CGFloat = 20
    private static let transientOverlayStatusTexts: Set<String> = [
        "Transcribing",
        "Refining",
        "Thinking",
        "Working",
        "Transcribing...",
        "Refining...",
        "Thinking...",
        "Working...",
    ]

    private var compactPreviewText: String {
        let source = self.contentState.isProcessing
            ? self.contentState.transcriptionText
            : self.contentState.cachedPreviewText
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Self.transientOverlayStatusTexts.contains(trimmed) else { return "" }
        return trimmed
    }

    private var shouldShowPreview: Bool {
        SettingsStore.shared.enableStreamingPreview && !self.compactPreviewText.isEmpty
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Text(self.compactPreviewText)
                .font(.fluidSystem(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.head)
                .offset(y: self.shouldShowPreview ? 0 : -4)
                .opacity(self.shouldShowPreview ? 1 : 0)
        }
        .frame(width: self.previewWidth, height: SettingsStore.shared.enableStreamingPreview ? self.previewHeight : 0, alignment: .leading)
        .padding(.horizontal, SettingsStore.shared.enableStreamingPreview ? 10 : 0)
        .padding(.bottom, SettingsStore.shared.enableStreamingPreview ? 8 : 0)
        .clipped()
        .animation(.easeOut(duration: 0.2), value: self.shouldShowPreview)
    }
}

// MARK: - Expanded Command Output View (Interactive Notch)

struct NotchCommandOutputExpandedView: View {
    let audioPublisher: AnyPublisher<CGFloat, Never>
    let onDismiss: () -> Void
    let onSubmit: (String) async -> Bool
    let onNewChat: () -> Void
    let onSwitchChat: (String) -> Void
    let onClearChat: () -> Void

    @ObservedObject private var contentState = NotchContentState.shared
    @State private var inputText: String = ""
    /// The last send was refused; the draft stays and a line under the field says so.
    @State private var notSent = false

    private var previewMaxHeight: CGFloat {
        70
    }

    /// Dynamic height based on content (max half screen)
    private var dynamicHeight: CGFloat {
        let baseHeight: CGFloat = 120 // Minimum height
        let contentHeight = self.estimateContentHeight()
        let maxHeight = (NSScreen.main?.frame.height ?? 800) * 0.45 // 45% of screen
        return min(max(baseHeight, contentHeight), maxHeight)
    }

    private func estimateContentHeight() -> CGFloat {
        var height: CGFloat = 96 // Header + follow-up area

        // Estimate based on conversation history
        for message in self.contentState.commandConversationHistory {
            let lineCount = max(1, message.content.count / 40) // ~40 characters per line beside the label column
            height += CGFloat(lineCount) * 18 + 17 // Line height + padding + hairline
        }

        // Add streaming text height
        if !self.contentState.commandStreamingText.isEmpty {
            let lineCount = max(1, contentState.commandStreamingText.count / 40)
            height += CGFloat(lineCount) * 18 + 17
        }

        return height
    }

    var body: some View {
        VStack(spacing: 0) {
            self.headerView
            self.transcriptionPreview
            self.conversationArea
            self.inputArea
        }
        .frame(width: 380, height: self.dynamicHeight)
        .recordNearBlack()
        .clipShape(RoundedRectangle(cornerRadius: FWMetric.radiusWindow, style: .continuous))
        .recordFloat()
    }

    private func hairline() -> some View {
        Rectangle().fill(FWColor.lineRule).frame(height: FWMetric.lineHairline)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: FWMetric.space3) {
            HStack(spacing: FWMetric.space2) {
                if self.contentState.isRecordingInExpandedMode {
                    Text("Listening")
                        .recordText(FWType.smallStrong)
                        .foregroundStyle(FWColor.liveIvory)
                } else if self.contentState.isCommandProcessing {
                    Text("Working")
                        .recordText(FWType.smallStrong)
                        .foregroundStyle(FWColor.textSecondary)
                    RecordMark(state: .working)
                } else {
                    Text("Command")
                        .recordText(FWType.smallStrong)
                        .foregroundStyle(FWColor.textSecondary)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: FWMetric.space3) {
                Button("New", action: self.onNewChat)
                    .disabled(self.contentState.isCommandProcessing)
                    .help("New session")

                Menu {
                    let recentChats = self.contentState.recentChats
                    let currentID = ChatHistoryStore.shared.currentChatID
                    if recentChats.isEmpty {
                        Text("No recent sessions")
                    } else {
                        ForEach(recentChats) { chat in
                            Button(action: {
                                if chat.id != currentID {
                                    self.onSwitchChat(chat.id)
                                }
                            }) {
                                HStack {
                                    if chat.id == currentID {
                                        Image(systemName: "checkmark")
                                    }
                                    Text(chat.title)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(chat.relativeTimeString)
                                }
                            }
                            .disabled(self.contentState.isCommandProcessing)
                        }
                    }
                } label: {
                    Text("Recent")
                }
                .menuIndicator(.hidden)
                .menuStyle(.button)
                .fixedSize()
                .help("Recent sessions")

                Button("Delete", action: self.onClearChat)
                    .buttonStyle(RecordButtonStyle(kind: .destructive, size: FWMetric.sizeControlS))
                    .disabled(self.contentState.isCommandProcessing)
                    .help("Delete session")

                Button("Close", action: self.onDismiss)
                    .help("Close (Escape)")
            }
            .buttonStyle(RecordButtonStyle(kind: .secondary, size: FWMetric.sizeControlS))
        }
        .padding(.horizontal, FWMetric.space4)
        .padding(.vertical, FWMetric.space3)
        .overlay(alignment: .bottom) { self.hairline() }
        .onAppear {
            self.contentState.refreshRecentChats()
        }
    }

    // MARK: - Heard so far (shown while recording)

    private var transcriptionPreview: some View {
        Group {
            if self.contentState.isRecordingInExpandedMode && !self.contentState.transcriptionText.isEmpty {
                let previewText = self.contentState.cachedPreviewText
                if !previewText.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            Text(previewText)
                                .recordText(FWType.body)
                                .foregroundStyle(FWColor.textPrimary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .frame(maxWidth: .infinity, maxHeight: self.previewMaxHeight)
                        .clipped()
                        .onAppear {
                            DispatchQueue.main.async {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                        .onChange(of: previewText) { _, _ in
                            DispatchQueue.main.async {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                    .padding(.horizontal, FWMetric.space4)
                    .padding(.vertical, FWMetric.space3)
                    .overlay(alignment: .bottom) { self.hairline() }
                }
            }
        }
    }

    // MARK: - Conversation Area

    private var conversationArea: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let history = self.contentState.commandConversationHistory
                    ForEach(history) { message in
                        self.messageView(for: message, isLast: message.id == history.last?.id)
                            .id(message.id)
                    }

                    // Streaming text (real-time)
                    if !self.contentState.commandStreamingText.isEmpty {
                        self.row(label: "Answer", mark: nil) {
                            Text(self.contentState.commandStreamingText)
                                .recordText(FWType.body)
                                .foregroundStyle(FWColor.textPrimary)
                        }
                        .id("streaming")
                    }

                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, FWMetric.space4)
                .padding(.vertical, FWMetric.space2)
            }
            .onAppear {
                // Always scroll to bottom when view appears
                self.scrollToBottom(proxy)
            }
            .onChange(of: self.contentState.commandConversationHistory.count) { _, _ in
                self.scrollToBottom(proxy)
            }
            .onChange(of: self.contentState.commandStreamingText) { _, _ in
                self.scrollToBottom(proxy)
            }
            .onChange(of: self.contentState.isCommandProcessing) { _, _ in
                self.scrollToBottom(proxy)
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }

    // MARK: - Message Views

    @ViewBuilder
    private func messageView(for message: NotchContentState.CommandOutputMessage, isLast: Bool) -> some View {
        switch message.role {
        case .user:
            self.row(label: "You", mark: nil) {
                Text(message.content)
                    .recordText(FWType.body)
                    .foregroundStyle(FWColor.textPrimary)
                    .textSelection(.enabled)
            }
        case .assistant:
            self.row(label: "Answer", mark: nil) {
                Text(message.content)
                    .recordText(FWType.body)
                    .foregroundStyle(FWColor.textPrimary)
                    .textSelection(.enabled)
            }
        case .status:
            let running = isLast && self.contentState.isCommandProcessing
            self.row(label: running ? "Running" : "Ran", mark: running ? .working : .done) {
                Text(message.content)
                    .recordText(FWType.body)
                    .foregroundStyle(FWColor.textSecondary)
            }
        }
    }

    /// One message: a 64 pt label column, then the text, with a hairline under it.
    private func row(label: String, mark: RecordMark.State?, @ViewBuilder text: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: FWMetric.space3) {
            HStack(spacing: FWMetric.space2) {
                Text(label)
                    .recordText(FWType.detail)
                    .foregroundStyle(FWColor.textTertiary)
                if let mark { RecordMark(state: mark) }
            }
            .frame(width: 64, alignment: .leading)
            text()
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, FWMetric.space3)
        .overlay(alignment: .bottom) { self.hairline() }
    }

    // MARK: - Follow-up Area

    private var canSend: Bool {
        !self.inputText.isEmpty && !self.contentState.isCommandProcessing && !self.contentState.isRecordingInExpandedMode
    }

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: FWMetric.space2) {
            HStack(spacing: FWMetric.space3) {
                RecordField(placeholder: "Ask a follow-up", text: self.$inputText)
                    .onSubmit {
                        self.submitFollowUp()
                    }
                Button("Send", action: self.submitFollowUp)
                    .buttonStyle(RecordButtonStyle(kind: .primary, size: FWMetric.sizeControlS))
                    .disabled(!self.canSend)
            }
            if self.notSent {
                Text("Not sent. Your text is still here.")
                    .recordText(FWType.small)
                    .foregroundStyle(FWColor.stateAttention)
            }
        }
        .padding(EdgeInsets(top: FWMetric.space3, leading: FWMetric.space4, bottom: FWMetric.space4, trailing: FWMetric.space4))
        .overlay(alignment: .top) { self.hairline() }
        .onChange(of: self.inputText) { _, _ in self.notSent = false }
    }

    private func submitFollowUp() {
        guard self.canSend else { return }
        let text = self.inputText

        Task {
            await FollowUpDraft.submit(
                text,
                send: { text in
                    let sent = await self.onSubmit(text)
                    self.notSent = !sent
                    return sent
                },
                currentText: { self.inputText },
                clear: { self.inputText = "" }
            )
        }
    }
}

struct CompactNotchWaveformView: View {
    private static let storedBarCount = 8

    let audioPublisher: AnyPublisher<CGFloat, Never>
    let color: Color
    var barCount: Int = 8

    @StateObject private var data: AudioVisualizationData
    @ObservedObject private var contentState = NotchContentState.shared
    @State private var barHeights: [CGFloat] = Array(
        repeating: 3,
        count: CompactNotchWaveformView.storedBarCount
    )

    private let barWidth: CGFloat = 2.5
    private let barSpacing: CGFloat = 2
    private let minHeight: CGFloat = 3
    private let maxHeight: CGFloat = 15
    private let noiseThreshold: CGFloat = 0.05
    private let processingFlatHeight: CGFloat = 3

    init(audioPublisher: AnyPublisher<CGFloat, Never>, color: Color, barCount: Int = 8) {
        self.audioPublisher = audioPublisher
        self.color = color
        self.barCount = min(max(barCount, 1), Self.storedBarCount)
        _data = StateObject(wrappedValue: AudioVisualizationData(audioLevelPublisher: audioPublisher))
    }

    var body: some View {
        ZStack {
            if self.contentState.isDictationMuted {
                DictationMutedIndicator(compact: true)
            } else {
                self.barsView(using: { index in
                    self.displayHeight(for: index)
                })
                .foregroundStyle(self.color.opacity(self.contentState.isProcessing ? 0.16 : 1.0))

                if self.contentState.isProcessing {
                    CompositorShimmerSweep(duration: 1.05, peakOpacity: 0.9)
                        .mask {
                            self.barsView(using: { index in
                                self.displayHeight(for: index)
                            })
                        }
                        .shadow(color: .white.opacity(0.28), radius: 2.5, x: 0, y: 0)
                }
            }
        }
        .onChange(of: self.data.audioLevel) { _, level in
            if !self.contentState.isProcessing {
                self.updateBars(level: level)
            }
        }
        .onChange(of: self.contentState.isProcessing) { _, processing in
            if processing {
                self.resetBarsToBaseline(animated: false)
            } else {
                self.updateBars(level: self.data.audioLevel)
            }
        }
        .onAppear {
            if self.contentState.isProcessing {
                self.resetBarsToBaseline(animated: false)
            } else {
                self.updateBars(level: self.data.audioLevel)
            }
        }
    }

    private func barsView(using height: @escaping (Int) -> CGFloat) -> some View {
        HStack(spacing: self.barSpacing) {
            ForEach(0..<self.barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: self.barWidth / 2)
                    .frame(width: self.barWidth, height: height(index))
            }
        }
    }

    private func displayHeight(for index: Int) -> CGFloat {
        guard self.contentState.isProcessing else {
            return self.barHeights[index]
        }

        return self.processingFlatHeight
    }

    private func updateBars(level: CGFloat) {
        let normalizedLevel = min(max(level, 0), 1)
        let adjustedLevel = normalizedLevel > self.noiseThreshold
            ? (normalizedLevel - self.noiseThreshold) / (1.0 - self.noiseThreshold)
            : 0

        guard adjustedLevel > 0 else {
            self.resetBarsToBaseline(animated: false)
            return
        }

        withAnimation(.easeOut(duration: 0.1)) {
            for index in 0..<self.barCount {
                let centerDistance = abs(CGFloat(index) - CGFloat(self.barCount - 1) / 2)
                let centerFactor = 1.0 - (centerDistance / CGFloat(self.barCount / 2)) * 0.28
                self.barHeights[index] = self.minHeight + (self.maxHeight - self.minHeight) * adjustedLevel * centerFactor
            }
        }
    }

    private func resetBarsToBaseline(animated: Bool) {
        let apply = {
            self.barHeights = Array(repeating: self.minHeight, count: Self.storedBarCount)
        }

        if animated {
            withAnimation(.easeOut(duration: 0.08)) {
                apply()
            }
        } else {
            apply()
        }
    }
}
